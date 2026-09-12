import XCTest

@testable import StorageCleanerMac

final class BenchmarkV7ReferenceCatalogTests: XCTestCase {
    func testProductionV9VersionAndDurationContractIsFrozen() {
        let plan = BenchmarkV7Plan.standard
        let versions = BenchmarkV7ReferenceCatalog.versions(for: plan)
        let official = OfficialBenchmarkPlan.current

        XCTAssertEqual(plan.planVersion, "benchmark-standard-plan-v9")
        XCTAssertEqual(plan.workloadVersion, "benchmark-standard-v9")
        XCTAssertEqual(versions.scoringVersion, "benchmark-scoring-v9")
        XCTAssertEqual(versions.referenceSetVersion, "local-m5-pro-controlled-v9-r1")
        XCTAssertEqual(BenchmarkV7ReferenceCatalog.referenceSet.version, versions.referenceSetVersion)
        XCTAssertEqual(official.expectedMinimumDurationSeconds, 14 * 60)
        XCTAssertEqual(official.expectedMaximumDurationSeconds, 16 * 60)
    }

    func testLeaderboardServerUsesTheSameProductionV9Contract() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Server/BenchmarkLeaderboard/src/v2-contracts.ts"
            ),
            encoding: .utf8
        )
        let versions = BenchmarkV7ReferenceCatalog.versions(for: .standard)

        for value in [
            versions.planVersion,
            versions.workloadVersion,
            versions.scoringVersion,
            versions.referenceSetVersion,
        ] {
            XCTAssertTrue(source.contains("\"\(value)\""), "Server contract missing \(value)")
        }
    }

    func testStandardCatalogHasValidControlledReferenceSetAndManifest() throws {
        let plan = BenchmarkV7Plan.standard
        let manifest = try XCTUnwrap(BenchmarkV7ReferenceCatalog.scoringManifest(for: plan))

        XCTAssertTrue(BenchmarkV7ReferenceCatalog.referenceSet.isValid)
        XCTAssertTrue(manifest.versions.isValid)
        XCTAssertTrue(manifest.isValid)
        XCTAssertEqual(manifest.displayBaseline, 6_000)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: manifest.coreCategoryWeights.map { ($0.category, $0.weight) }),
            [.cpu: 0.35, .gpu: 0.25, .memory: 0.20, .storage: 0.20]
        )
    }

    func testStandardReferenceMetricsScoreExactlyAtDisplayBaseline() throws {
        let plan = BenchmarkV7Plan.standard
        let manifest = try XCTUnwrap(BenchmarkV7ReferenceCatalog.scoringManifest(for: plan))
        let measurements = Dictionary(
            uniqueKeysWithValues: BenchmarkV7ReferenceCatalog.referenceSet.metrics.map {
                ($0.key, $0.value.value)
            }
        )

        let score = try BenchmarkV7Scoring.scoreCore(
            plan: plan,
            manifest: manifest,
            referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
            measurements: measurements
        )

        XCTAssertEqual(score.overallScore, 6_000, accuracy: 0.000_001)
    }

    func testMissingStorageMetricsRefuseFormalCoreScore() throws {
        let plan = BenchmarkV7Plan.standard
        let manifest = try XCTUnwrap(BenchmarkV7ReferenceCatalog.scoringManifest(for: plan))
        var measurements = referenceMeasurements()
        manifest.metrics.filter { $0.category == .storage }.forEach {
            measurements.removeValue(forKey: $0.id)
        }

        XCTAssertThrowsError(
            try BenchmarkV7Scoring.scoreCore(
                plan: plan,
                manifest: manifest,
                referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
                measurements: measurements
            )
        ) { error in
            XCTAssertEqual(error as? BenchmarkV7ScoringError, .missingCategory(.storage))
        }
    }

    func testDisplayMeasurementsDoNotChangeCoreScore() throws {
        let plan = BenchmarkV7Plan.standard
        let manifest = try XCTUnwrap(BenchmarkV7ReferenceCatalog.scoringManifest(for: plan))
        let baseline = try BenchmarkV7Scoring.scoreCore(
            plan: plan,
            manifest: manifest,
            referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
            measurements: referenceMeasurements()
        )
        var displayChanged = referenceMeasurements()
        displayChanged["display.p95FrameTime"] = 0.001

        let score = try BenchmarkV7Scoring.scoreCore(
            plan: plan,
            manifest: manifest,
            referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
            measurements: displayChanged
        )

        XCTAssertEqual(score.overallScore, baseline.overallScore, accuracy: 0.000_001)
        XCTAssertNil(score.categoryScores[.display])
    }

    private func referenceMeasurements() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: BenchmarkV7ReferenceCatalog.referenceSet.metrics.map {
            ($0.key, $0.value.value)
        })
    }
}
