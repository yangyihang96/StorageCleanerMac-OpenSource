import XCTest
@testable import StorageCleanerMac

final class BenchmarkV7ScoringFoundationTests: XCTestCase {
    func testReferenceMeasurementsProduceDisplayBaselineAndExcludeDisplay() throws {
        let fixture = makeFixture()
        let baseline = try BenchmarkV7Scoring.scoreCore(
            plan: fixture.plan,
            manifest: fixture.manifest,
            referenceSet: fixture.referenceSet,
            measurements: fixture.measurements
        )
        XCTAssertEqual(baseline.overallScore, 6_000, accuracy: 0.000_001)
        XCTAssertEqual(baseline.categoryScores.count, 4)
        XCTAssertNil(baseline.categoryScores[.display])

        var changedDisplay = fixture.measurements
        changedDisplay["display.p95FrameTime"] = 0.001
        let unchangedCore = try BenchmarkV7Scoring.scoreCore(
            plan: fixture.plan,
            manifest: fixture.manifest,
            referenceSet: fixture.referenceSet,
            measurements: changedDisplay
        )
        XCTAssertEqual(unchangedCore.overallScore, baseline.overallScore, accuracy: 0.000_001)
    }

    func testLowerIsBetterMetricUsesInverseReferenceRatio() throws {
        let fixture = makeFixture()
        var measurements = fixture.measurements
        measurements["storage.p95Latency"] = 0.005

        let result = try BenchmarkV7Scoring.scoreCore(
            plan: fixture.plan,
            manifest: fixture.manifest,
            referenceSet: fixture.referenceSet,
            measurements: measurements
        )
        XCTAssertEqual(
            result.categoryScores[.storage]?.ratio ?? -1,
            2,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(result.overallScore, 6_000)
    }

    func testMissingCoreCategoryRefusesFormalScoreInsteadOfReweighting() {
        let fixture = makeFixture()
        var measurements = fixture.measurements
        measurements.removeValue(forKey: "storage.p95Latency")

        XCTAssertThrowsError(
            try BenchmarkV7Scoring.scoreCore(
                plan: fixture.plan,
                manifest: fixture.manifest,
                referenceSet: fixture.referenceSet,
                measurements: measurements
            )
        ) { error in
            XCTAssertEqual(error as? BenchmarkV7ScoringError, .missingCategory(.storage))
        }
    }

    func testInvalidValuesAreRejectedWithoutEpsilonFallback() {
        let fixture = makeFixture()
        for value in [0, -1, Double.nan, Double.infinity] {
            var measurements = fixture.measurements
            measurements["cpu.single"] = value
            XCTAssertThrowsError(
                try BenchmarkV7Scoring.scoreCore(
                    plan: fixture.plan,
                    manifest: fixture.manifest,
                    referenceSet: fixture.referenceSet,
                    measurements: measurements
                )
            ) { error in
                XCTAssertEqual(
                    error as? BenchmarkV7ScoringError,
                    .invalidMetricValue("cpu.single")
                )
            }
        }
    }

    func testCompatibilityKeepsLegacyAndVersionMismatchesSeparate() {
        let fixture = makeFixture()
        XCTAssertEqual(
            BenchmarkV7Compatibility.classify(
                stored: nil,
                current: fixture.manifest.versions
            ),
            .legacy
        )
        XCTAssertEqual(
            BenchmarkV7Compatibility.classify(
                stored: fixture.manifest.versions,
                current: fixture.manifest.versions
            ),
            .directlyComparable
        )

        let changedReference = BenchmarkV7VersionManifest(
            planVersion: fixture.manifest.versions.planVersion,
            workloadVersion: fixture.manifest.versions.workloadVersion,
            statisticsVersion: fixture.manifest.versions.statisticsVersion,
            scoringVersion: fixture.manifest.versions.scoringVersion,
            referenceSetVersion: "reference-v7-next"
        )
        XCTAssertEqual(
            BenchmarkV7Compatibility.classify(
                stored: changedReference,
                current: fixture.manifest.versions
            ),
            .incompatible
        )
    }

    private func makeFixture() -> (
        plan: BenchmarkV7Plan,
        manifest: BenchmarkV7ScoringManifest,
        referenceSet: BenchmarkV7ReferenceSet,
        measurements: [String: Double]
    ) {
        let plan = BenchmarkV7Plan.standard
        let versions = BenchmarkV7VersionManifest(
            planVersion: plan.planVersion,
            workloadVersion: plan.workloadVersion,
            statisticsVersion: "benchmark-statistics-v7",
            scoringVersion: "benchmark-scoring-v7",
            referenceSetVersion: "reference-v7"
        )
        let metrics = [
            BenchmarkV7MetricManifest(
                id: "cpu.single",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: plan.workloadVersion
            ),
            BenchmarkV7MetricManifest(
                id: "gpu.graphics",
                category: .gpu,
                unit: "Mtri/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: plan.workloadVersion
            ),
            BenchmarkV7MetricManifest(
                id: "memory.copy",
                category: .memory,
                unit: "GB/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: plan.workloadVersion
            ),
            BenchmarkV7MetricManifest(
                id: "storage.p95Latency",
                category: .storage,
                unit: "s",
                direction: .lowerIsBetter,
                weight: 1,
                workloadVersion: plan.workloadVersion
            ),
            BenchmarkV7MetricManifest(
                id: "display.p95FrameTime",
                category: .display,
                unit: "s",
                direction: .lowerIsBetter,
                weight: 1,
                workloadVersion: plan.workloadVersion
            ),
        ]
        let manifest = BenchmarkV7ScoringManifest(
            versions: versions,
            displayBaseline: 6_000,
            coreCategoryWeights: [
                BenchmarkV7CategoryWeight(category: .cpu, weight: 0.35),
                BenchmarkV7CategoryWeight(category: .gpu, weight: 0.25),
                BenchmarkV7CategoryWeight(category: .memory, weight: 0.20),
                BenchmarkV7CategoryWeight(category: .storage, weight: 0.20),
            ],
            metrics: metrics
        )
        let referenceSet = BenchmarkV7ReferenceSet(
            version: versions.referenceSetVersion,
            supportedWorkloadVersions: [plan.workloadVersion],
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            sourceDescription: "Controlled fixture reference",
            metrics: [
                "cpu.single": referenceMetric(
                    id: "cpu.single", value: 100, unit: "Mops/s", direction: .higherIsBetter
                ),
                "gpu.graphics": referenceMetric(
                    id: "gpu.graphics", value: 200, unit: "Mtri/s", direction: .higherIsBetter
                ),
                "memory.copy": referenceMetric(
                    id: "memory.copy", value: 50, unit: "GB/s", direction: .higherIsBetter
                ),
                "storage.p95Latency": referenceMetric(
                    id: "storage.p95Latency", value: 0.010, unit: "s", direction: .lowerIsBetter
                ),
                "display.p95FrameTime": referenceMetric(
                    id: "display.p95FrameTime", value: 0.016, unit: "s", direction: .lowerIsBetter
                ),
            ]
        )
        return (
            plan,
            manifest,
            referenceSet,
            [
                "cpu.single": 100,
                "gpu.graphics": 200,
                "memory.copy": 50,
                "storage.p95Latency": 0.010,
                "display.p95FrameTime": 0.016,
            ]
        )
    }

    private func referenceMetric(
        id: String,
        value: Double,
        unit: String,
        direction: BenchmarkV7MetricDirection
    ) -> BenchmarkV7ReferenceMetric {
        BenchmarkV7ReferenceMetric(
            id: id,
            value: value,
            unit: unit,
            direction: direction,
            sourceDescription: "Controlled fixture reference",
            sampleCount: 5,
            validationStatus: .controlledLocal
        )
    }
}
