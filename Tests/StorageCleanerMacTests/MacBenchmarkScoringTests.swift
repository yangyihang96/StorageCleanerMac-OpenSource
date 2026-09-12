import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkScoringTests: XCTestCase {
    func testReferenceUsesOneThousandPerComponentAndSixThousandTotal() {
        XCTAssertEqual(MacBenchmarkScoring.referenceScore, 1_000)
        XCTAssertEqual(MacBenchmarkScoring.referenceTotalScore, 6_000)
    }

    func testUnknownFutureWorkloadIsNotSilentlyScoredAsDirectSum() throws {
        let raw = completeRawResult(
            metrics: referenceMetrics(),
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v7"
        )
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())

        XCTAssertFalse(MacBenchmarkScoring.isSupportedWorkloadVersion(
            raw.workloadVersion,
            profile: raw.profile
        ))
        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: raw, against: baseline)
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkScoringError,
                .unsupportedWorkloadVersion
            )
        }
        XCTAssertFalse(MacBenchmarkScoring.usesLegacyV2WeightedIndex(
            workloadVersion: "future-custom-v2"
        ))
    }

    func testExactReferenceProducesOneThousandPerComponentAndSixThousandTotal() throws {
        let metrics = referenceMetrics()
        let raw = completeRawResult(metrics: metrics)
        let baseline = try verifiedBaseline(
            raw: raw,
            references: metrics
        )

        let result = try MacBenchmarkScoring().score(
            rawResult: raw,
            against: baseline
        )

        XCTAssertEqual(
            try XCTUnwrap(result.overallScore),
            MacBenchmarkScoring.referenceTotalScore,
            accuracy: 0.000_001
        )
        for component in BenchmarkComponent.allCases {
            XCTAssertEqual(
                try XCTUnwrap(result.componentScores[component]),
                MacBenchmarkScoring.referenceScore,
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(result.comparisonKey, baseline.baseline.comparisonKey)
        XCTAssertEqual(result.matchedBaselineKey, baseline.baseline.comparisonKey)
    }

    func testDisplayScoreKeepsAnUnstableCompleteRunVisibleButUntrusted() throws {
        let metrics = referenceMetrics()
        let raw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            samplesByComponent: [.cpuSingle: [80, 100, 120]]
        )
        let baseline = try verifiedBaseline(raw: raw, references: metrics)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: baseline.baseline.comparisonKey.baselineVersion,
            verifiedBaselines: [baseline]
        )
        let rawOnly = MacBenchmarkScoring.rawOnly(rawResult: raw)

        let display = try XCTUnwrap(MacBenchmarkDisplayScoring.score(
            for: rawOnly,
            baselineCatalog: catalog
        ))

        XCTAssertFalse(MacBenchmarkScoring.hasComparableMeasurementStability(raw))
        XCTAssertNil(rawOnly.overallScore)
        XCTAssertEqual(display.overallScore, 6_000, accuracy: 0.000_001)
        XCTAssertEqual(display.componentScores.count, BenchmarkComponent.allCases.count)
    }

    func testLegacyV2ReferenceKeepsItsOriginalOneThousandPointIndex() throws {
        let metrics = referenceMetrics()
        let raw = completeRawResult(
            metrics: metrics,
            workloadVersion: "mac-benchmark-quick-v2"
        )
        let baseline = try verifiedBaseline(raw: raw, references: metrics)

        let result = try MacBenchmarkScoring().score(
            rawResult: raw,
            against: baseline
        )

        XCTAssertEqual(try XCTUnwrap(result.overallScore), 1_000, accuracy: 0.000_001)
        XCTAssertTrue(MacBenchmarkScoring.usesLegacyV2WeightedIndex(
            workloadVersion: raw.workloadVersion
        ))
    }

    func testRatiosClampBetweenPointTwoAndFiveBeforeDirectSummation() throws {
        let references = referenceMetrics(value: 100)
        var measured = references
        measured[.cpuSingle] = 1_000
        measured[.diskWrite] = 1
        let raw = completeRawResult(metrics: measured)
        let baseline = try verifiedBaseline(raw: raw, references: references)

        let result = try MacBenchmarkScoring().score(
            rawResult: raw,
            against: baseline
        )

        XCTAssertEqual(
            try XCTUnwrap(result.componentScores[.cpuSingle]),
            5_000,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(result.componentScores[.diskWrite]),
            200,
            accuracy: 0.000_001
        )
        let expected = 5_000.0 + 200.0 + 4_000.0
        XCTAssertEqual(
            try XCTUnwrap(result.overallScore),
            expected,
            accuracy: 0.000_001
        )
    }

    func testStandardV5IncludesBoundedMemoryAndDiskCapacity() throws {
        let metrics = referenceMetrics()
        let referenceRaw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.capacityAwareWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes,
            systemDiskCapacityBytes: MacBenchmarkScoring.referenceSystemDiskCapacityBytes
        )
        let baseline = try verifiedBaseline(raw: referenceRaw, references: metrics)
        let referenceResult = try MacBenchmarkScoring().score(
            rawResult: referenceRaw,
            against: baseline
        )
        XCTAssertEqual(
            try XCTUnwrap(referenceResult.overallScore),
            6_000,
            accuracy: 0.000_001
        )

        let smallerCapacityRaw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.capacityAwareWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes / 4,
            systemDiskCapacityBytes:
                MacBenchmarkScoring.referenceSystemDiskCapacityBytes / 4
        )
        let smallerResult = try MacBenchmarkScoring().score(
            rawResult: smallerCapacityRaw,
            against: baseline
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerResult.componentScores[.memory]),
            875,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerResult.componentScores[.diskRead]),
            950,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerResult.componentScores[.diskWrite]),
            950,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerResult.overallScore),
            5_775,
            accuracy: 0.000_001
        )
    }

    func testStandardV5RejectsMissingDiskCapacity() throws {
        let raw = completeRawResult(
            metrics: referenceMetrics(),
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.capacityAwareWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes,
            systemDiskCapacityBytes: nil
        )
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())
        XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(raw))
        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: raw, against: baseline)
        ) { error in
            XCTAssertEqual(error as? MacBenchmarkScoringError, .nonComparableEnvironment)
        }
    }

    func testStandardV6IncludesBoundedMemoryAndDiskCapacity() throws {
        let metrics = referenceMetrics()
        let referenceRaw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes,
            systemDiskCapacityBytes: MacBenchmarkScoring.referenceSystemDiskCapacityBytes
        )
        let baseline = try verifiedBaseline(raw: referenceRaw, references: metrics)

        let referenceResult = try MacBenchmarkScoring().score(
            rawResult: referenceRaw,
            against: baseline
        )
        XCTAssertEqual(
            try XCTUnwrap(referenceResult.overallScore),
            6_000,
            accuracy: 0.000_001
        )

        let smallerCapacityRaw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes / 4,
            systemDiskCapacityBytes:
                MacBenchmarkScoring.referenceSystemDiskCapacityBytes / 4
        )
        let smallerCapacityResult = try MacBenchmarkScoring().score(
            rawResult: smallerCapacityRaw,
            against: baseline
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerCapacityResult.componentScores[.memory]),
            875,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerCapacityResult.componentScores[.diskRead]),
            950,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(smallerCapacityResult.componentScores[.diskWrite]),
            950,
            accuracy: 0.000_001
        )
        let expected = 6_000 * pow(0.875, 0.20) * pow(0.95, 0.20)
        XCTAssertEqual(
            try XCTUnwrap(smallerCapacityResult.overallScore),
            expected,
            accuracy: 0.000_001
        )
    }

    func testStandardV6DoublesWhenEveryMetricDoubles() throws {
        let references = referenceMetrics()
        let referenceRaw = completeRawResult(
            metrics: references,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )
        let baseline = try verifiedBaseline(raw: referenceRaw, references: references)
        let doubled = references.mapValues { $0 * 2 }
        let result = try MacBenchmarkScoring().score(
            rawResult: completeRawResult(
                metrics: doubled,
                profile: .standard,
                workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
            ),
            against: baseline
        )

        for component in [BenchmarkComponent.cpuSingle, .cpuMulti, .gpu] {
            XCTAssertEqual(
                try XCTUnwrap(result.componentScores[component]),
                2_000,
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(result.componentScores[.memory]),
            1_750,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(result.componentScores[.diskRead]),
            1_900,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(result.componentScores[.diskWrite]),
            1_900,
            accuracy: 0.000_001
        )
        let expected = 6_000
            * pow(2, 0.14 + 0.21 + 0.25)
            * pow(1.75, 0.20)
            * pow(1.9, 0.11 + 0.09)
        XCTAssertEqual(
            try XCTUnwrap(result.overallScore),
            expected,
            accuracy: 0.000_001
        )
    }

    func testStandardV6RejectsMissingCapacityEvidence() throws {
        let raw = completeRawResult(
            metrics: referenceMetrics(),
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            physicalMemoryBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes,
            systemDiskCapacityBytes: nil
        )
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())

        XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(raw))
        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: raw, against: baseline)
        ) { error in
            XCTAssertEqual(error as? MacBenchmarkScoringError, .nonComparableEnvironment)
        }
    }

    func testStandardV6UsesDeclaredGeometricWeightForOneFastComponent() throws {
        let references = referenceMetrics()
        let referenceRaw = completeRawResult(
            metrics: references,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )
        let baseline = try verifiedBaseline(raw: referenceRaw, references: references)
        var measured = references
        measured[.gpu] = try XCTUnwrap(references[.gpu]) * 5

        let result = try MacBenchmarkScoring().score(
            rawResult: completeRawResult(
                metrics: measured,
                profile: .standard,
                workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
            ),
            against: baseline
        )

        XCTAssertEqual(
            try XCTUnwrap(result.overallScore),
            6_000 * pow(5, 0.25),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MacBenchmarkScoring.balancedComponentWeights.values.reduce(0, +),
            1,
            accuracy: 0.000_000_1
        )
    }

    func testStandardV6AcceptsRatioBoundariesAndRejectsValuesOutsideThem() throws {
        let references = referenceMetrics()
        let referenceRaw = completeRawResult(
            metrics: references,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )
        let baseline = try verifiedBaseline(raw: referenceRaw, references: references)

        for ratio in [
            MacBenchmarkScoring.minimumAcceptedPerformanceRatio,
            MacBenchmarkScoring.maximumAcceptedPerformanceRatio,
        ] {
            var measured = references
            measured[.cpuSingle] = try XCTUnwrap(references[.cpuSingle]) * ratio
            XCTAssertNoThrow(try MacBenchmarkScoring().score(
                rawResult: completeRawResult(
                    metrics: measured,
                    profile: .standard,
                    workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
                ),
                against: baseline
            ))
        }

        for ratio in [0.019_999, 5.000_001] {
            var measured = references
            measured[.cpuSingle] = try XCTUnwrap(references[.cpuSingle]) * ratio
            XCTAssertThrowsError(try MacBenchmarkScoring().score(
                rawResult: completeRawResult(
                    metrics: measured,
                    profile: .standard,
                    workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
                ),
                against: baseline
            )) { error in
                XCTAssertEqual(
                    error as? MacBenchmarkScoringError,
                    .performanceRatioOutsideAcceptedRange(.cpuSingle)
                )
            }
        }
    }

    func testStandardV6UsesComponentSpecificStabilityGates() throws {
        let metrics = referenceMetrics()
        let stableRaw = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            samplesByComponent: [
                .cpuSingle: [95, 100, 105],
                .gpu: [90, 100, 110],
                .diskWrite: [90, 100, 110],
            ]
        )
        XCTAssertTrue(MacBenchmarkScoring.hasComparableEnvironment(stableRaw))

        let unstableCPU = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            samplesByComponent: [.cpuSingle: [94, 100, 106]]
        )
        XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(unstableCPU))

        let unstableGPU = completeRawResult(
            metrics: metrics,
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            samplesByComponent: [.gpu: [89, 100, 111]]
        )
        XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(unstableGPU))
    }

    func testStandardV6RequiresComparablePostflightDiskSnapshotWithoutBreakingV3() {
        let legacy = completeRawResult(metrics: referenceMetrics())
        let legacyPostflight = BenchmarkPostflight(
            capturedAt: legacy.postflight!.capturedAt,
            powerSource: .acPower,
            lowPowerModeEnabled: false,
            thermalState: .nominal
        )
        XCTAssertTrue(
            MacBenchmarkScoring.hasComparableEnvironment(
                replacingPostflight(in: legacy, with: legacyPostflight)
            )
        )

        let v6 = completeRawResult(
            metrics: referenceMetrics(),
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )
        XCTAssertFalse(
            MacBenchmarkScoring.hasComparableEnvironment(
                replacingPostflight(in: v6, with: legacyPostflight)
            )
        )

        let completedAt = v6.completedAt!
        let unsafePostflights = [
            BenchmarkPostflight(
                capturedAt: completedAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .failing,
                availableDiskBytes: 100,
                requiredDiskBytes: 10,
                warnings: [.diskReliabilityFailing]
            ),
            BenchmarkPostflight(
                capturedAt: completedAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 9,
                requiredDiskBytes: 10,
                warnings: [.insufficientDiskCapacity]
            ),
            BenchmarkPostflight(
                capturedAt: completedAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .unavailable,
                availableDiskBytes: 100,
                requiredDiskBytes: 10,
                warnings: []
            ),
            BenchmarkPostflight(
                capturedAt: completedAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100,
                requiredDiskBytes: 11,
                warnings: []
            ),
        ]

        for postflight in unsafePostflights {
            XCTAssertFalse(
                MacBenchmarkScoring.hasComparableEnvironment(
                    replacingPostflight(in: v6, with: postflight)
                )
            )
        }
    }

    func testMissingZeroAndNonFiniteReferencesAreRejected() {
        let raw = completeRawResult(metrics: referenceMetrics())
        let report = Data("calibration-report".utf8)
        let hash = MacBenchmarkBaselineVerification.sha256Hex(report)
        for invalid in [Double.zero, -.infinity, .infinity, .nan] {
            var references = referenceMetrics()
            references[.gpu] = invalid
            let baseline = makeBaseline(
                raw: raw,
                references: references,
                reportSHA256: hash
            )
            XCTAssertThrowsError(
                try VerifiedMacBenchmarkBaseline(
                    baseline: baseline,
                    calibrationReport: report
                )
            ) { error in
                XCTAssertEqual(error as? MacBenchmarkBaselineError, .invalidBaseline)
            }
        }

        var missing = referenceMetrics()
        missing.removeValue(forKey: .memory)
        XCTAssertThrowsError(
            try VerifiedMacBenchmarkBaseline(
                baseline: makeBaseline(
                    raw: raw,
                    references: missing,
                    reportSHA256: hash
                ),
                calibrationReport: report
            )
        )
    }

    func testCalibrationReportHashMismatchRejectsBaseline() {
        let raw = completeRawResult(metrics: referenceMetrics())
        let report = try! calibrationReportData(
            raw: raw,
            references: referenceMetrics()
        )
        let baseline = makeBaseline(
            raw: raw,
            references: referenceMetrics(),
            reportSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertThrowsError(
            try VerifiedMacBenchmarkBaseline(
                baseline: baseline,
                calibrationReport: report
            )
        ) { error in
            XCTAssertEqual(error as? MacBenchmarkBaselineError, .reportHashMismatch)
        }
    }

    func testCalibrationReportMustBindKeyMetricsHardwareAndFrozenDate() throws {
        let raw = completeRawResult(metrics: referenceMetrics())
        let reports = try [
            calibrationReportData(
                raw: raw,
                references: referenceMetrics(value: 200)
            ),
            calibrationReportData(
                raw: raw,
                references: referenceMetrics(),
                baselineVersion: "baseline-2"
            ),
            calibrationReportData(
                raw: raw,
                references: referenceMetrics(),
                referenceHardware: "Different Reference Mac"
            ),
            calibrationReportData(
                raw: raw,
                references: referenceMetrics(),
                frozenAt: Date(timeIntervalSince1970: 2_001)
            ),
        ]

        for report in reports {
            let baseline = makeBaseline(
                raw: raw,
                references: referenceMetrics(),
                reportSHA256: MacBenchmarkBaselineVerification.sha256Hex(report)
            )
            XCTAssertThrowsError(
                try VerifiedMacBenchmarkBaseline(
                    baseline: baseline,
                    calibrationReport: report
                )
            ) { error in
                XCTAssertEqual(
                    error as? MacBenchmarkBaselineError,
                    .calibrationReportMismatch
                )
            }
        }
    }

    func testScoringRejectsComparisonKeyMismatchAndIncompleteRawResult() throws {
        let raw = completeRawResult(metrics: referenceMetrics())
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())
        var wrongProfile = raw
        wrongProfile = MacBenchmarkRawResult(
            profile: .full,
            workloadVersion: wrongProfile.workloadVersion,
            startedAt: wrongProfile.startedAt,
            completedAt: wrongProfile.completedAt,
            environment: wrongProfile.environment,
            preflight: wrongProfile.preflight,
            postflight: wrongProfile.postflight,
            capabilitySet: wrongProfile.capabilitySet,
            measurements: wrongProfile.measurements,
            failure: wrongProfile.failure
        )

        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: wrongProfile, against: baseline)
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkScoringError,
                .unsupportedWorkloadVersion
            )
        }

        let incomplete = MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: nil,
            environment: raw.environment,
            preflight: raw.preflight,
            postflight: nil,
            capabilitySet: .all,
            measurements: raw.measurements,
            failure: .cancelled
        )
        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: incomplete, against: baseline)
        ) { error in
            XCTAssertEqual(error as? MacBenchmarkScoringError, .incompleteResult)
        }
    }

    func testUncalibratedX86ResultRemainsRawOnly() throws {
        let raw = completeRawResult(
            metrics: referenceMetrics(),
            architecture: .x86_64
        )
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "baseline-1",
            verifiedBaselines: []
        )

        XCTAssertEqual(catalog.lookup(matching: raw), .unsupportedArchitecture)
        let result = MacBenchmarkScoring.rawOnly(rawResult: raw)
        XCTAssertNil(result.comparisonKey)
        XCTAssertNil(result.overallScore)
        XCTAssertTrue(result.componentScores.isEmpty)
        XCTAssertTrue(result.isComplete)
    }

    func testDirectX86ScoringIsRejectedEvenWithMatchingVerifiedBaseline() throws {
        let raw = completeRawResult(
            metrics: referenceMetrics(),
            architecture: .x86_64
        )
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())

        XCTAssertThrowsError(
            try MacBenchmarkScoring().score(rawResult: raw, against: baseline)
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkScoringError,
                .nonComparableEnvironment
            )
        }
    }

    func testScoringRejectsNonComparablePowerLowPowerThermalAndTime() throws {
        let referenceRaw = completeRawResult(metrics: referenceMetrics())
        let baseline = try verifiedBaseline(
            raw: referenceRaw,
            references: referenceMetrics()
        )
        let completedAt = try XCTUnwrap(referenceRaw.completedAt)
        let cases: [MacBenchmarkRawResult] = [
            environmentVariant(
                referenceRaw,
                powerSource: .battery
            ),
            environmentVariant(
                referenceRaw,
                lowPowerModeEnabled: true
            ),
            environmentVariant(
                referenceRaw,
                thermalState: .serious
            ),
            environmentVariant(
                referenceRaw,
                postflightCapturedAt: completedAt.addingTimeInterval(1)
            ),
            environmentVariant(
                referenceRaw,
                diskReliability: .failing
            ),
            environmentVariant(
                referenceRaw,
                availableDiskBytes: 5
            ),
            environmentVariant(
                referenceRaw,
                warnings: [.batteryTooLow]
            ),
        ]

        for raw in cases {
            XCTAssertTrue(raw.isComplete)
            XCTAssertThrowsError(
                try MacBenchmarkScoring().score(rawResult: raw, against: baseline)
            ) { error in
                XCTAssertEqual(
                    error as? MacBenchmarkScoringError,
                    .nonComparableEnvironment
                )
            }
        }
    }

    func testCatalogSeparatesMissingAmbiguousAndActiveVersion() throws {
        let raw = completeRawResult(metrics: referenceMetrics())
        let active = try verifiedBaseline(
            raw: raw,
            references: referenceMetrics(),
            baselineVersion: "baseline-2"
        )
        let inactive = try verifiedBaseline(
            raw: raw,
            references: referenceMetrics(),
            baselineVersion: "baseline-1"
        )

        XCTAssertEqual(
            try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "baseline-2",
                verifiedBaselines: []
            ).lookup(matching: raw),
            .notFound
        )
        XCTAssertEqual(
            try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "baseline-2",
                verifiedBaselines: [inactive, active]
            ).lookup(matching: raw),
            .matched(active)
        )
        XCTAssertEqual(
            try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "baseline-2",
                verifiedBaselines: [active, active]
            ).lookup(matching: raw),
            .ambiguous
        )
    }

    func testCatalogRejectsEmptyActiveBaselineVersion() {
        XCTAssertThrowsError(
            try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "  \n",
                verifiedBaselines: []
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkBaselineCatalogError,
                .invalidActiveBaselineVersion
            )
        }
    }

    func testAppAndBuildMetadataDoNotAffectBaselineLookup() throws {
        let raw = completeRawResult(metrics: referenceMetrics())
        let baseline = try verifiedBaseline(raw: raw, references: referenceMetrics())
        let changedEnvironment = BenchmarkEnvironmentMetadata(
            architecture: raw.environment.architecture,
            chipName: raw.environment.chipName,
            activeProcessorCount: raw.environment.activeProcessorCount,
            physicalMemoryBytes: raw.environment.physicalMemoryBytes,
            systemDiskCapacityBytes: raw.environment.systemDiskCapacityBytes,
            powerSource: raw.environment.powerSource,
            thermalState: raw.environment.thermalState,
            operatingSystemVersion: "macOS 99",
            appVersion: "9.9.9",
            appBuild: "999999"
        )
        let changed = MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: changedEnvironment,
            preflight: raw.preflight,
            postflight: raw.postflight,
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: nil
        )
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: baseline.baseline.comparisonKey.baselineVersion,
            verifiedBaselines: [baseline]
        )

        XCTAssertEqual(catalog.lookup(matching: changed), .matched(baseline))
    }

    func testVerifiedArm64BaselineScoresAcrossAppleSiliconFamilies() throws {
        let references = referenceMetrics()
        let referenceRun = completeRawResult(
            metrics: references,
            chipName: "Apple M5 Pro"
        )
        let baseline = try verifiedBaseline(raw: referenceRun, references: references)

        for chipName in [
            "Apple M1",
            "Apple M2 Pro",
            "Apple M3 Max",
            "Apple M4",
            "Apple M5 Ultra",
        ] {
            let raw = completeRawResult(metrics: references, chipName: chipName)
            let result = try MacBenchmarkScoring().score(
                rawResult: raw,
                against: baseline
            )

            XCTAssertEqual(
                try XCTUnwrap(result.overallScore),
                6_000,
                accuracy: 0.000_001,
                chipName
            )
        }
    }
}

private extension MacBenchmarkScoringTests {
    func referenceMetrics(value: Double = 100) -> [BenchmarkComponent: Double] {
        Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, value) })
    }

    func completeRawResult(
        metrics: [BenchmarkComponent: Double],
        architecture: BenchmarkArchitecture = .arm64,
        chipName: String = "Apple Test",
        profile: BenchmarkProfile = .quick,
        workloadVersion: String = "mac-benchmark-quick-v3",
        physicalMemoryBytes: UInt64 = MacBenchmarkScoring.referencePhysicalMemoryBytes,
        systemDiskCapacityBytes: UInt64? = MacBenchmarkScoring.referenceSystemDiskCapacityBytes,
        samplesByComponent: [BenchmarkComponent: [Double]] = [:]
    ) -> MacBenchmarkRawResult {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(10),
            environment: BenchmarkEnvironmentMetadata(
                architecture: architecture,
                chipName: chipName,
                activeProcessorCount: 8,
                physicalMemoryBytes: physicalMemoryBytes,
                systemDiskCapacityBytes: systemDiskCapacityBytes,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26",
                appVersion: "1.5.0",
                appBuild: "1"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt,
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100,
                requiredDiskBytes: 10,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(10),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100,
                requiredDiskBytes: 10,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: BenchmarkComponent.allCases.compactMap { component in
                guard let value = metrics[component] else { return nil }
                let defaultSampleCount = profile == .full ? 5 : 3
                let sampleValues = samplesByComponent[component]
                    ?? Array(repeating: value, count: defaultSampleCount)
                return BenchmarkComponentMeasurement(
                    component: component,
                    unit: component.metricUnit(for: profile),
                    samples: sampleValues.enumerated().map {
                        index, sampleValue in
                        BenchmarkComponentSample(
                            value: sampleValue,
                            elapsedSeconds: 1,
                            checksum: UInt64(component.rawValue.count + 1)
                        )
                    }
                )
            },
            failure: nil
        )
    }

    func verifiedBaseline(
        raw: MacBenchmarkRawResult,
        references: [BenchmarkComponent: Double],
        baselineVersion: String = "baseline-1"
    ) throws -> VerifiedMacBenchmarkBaseline {
        let report = try calibrationReportData(
            raw: raw,
            references: references,
            baselineVersion: baselineVersion
        )
        return try VerifiedMacBenchmarkBaseline(
            baseline: makeBaseline(
                raw: raw,
                references: references,
                reportSHA256: MacBenchmarkBaselineVerification.sha256Hex(report),
                baselineVersion: baselineVersion
            ),
            calibrationReport: report
        )
    }

    func makeBaseline(
        raw: MacBenchmarkRawResult,
        references: [BenchmarkComponent: Double],
        reportSHA256: String,
        baselineVersion: String = "baseline-1"
    ) -> MacBenchmarkBaseline {
        MacBenchmarkBaseline(
            comparisonKey: BenchmarkComparisonKey(
                workloadVersion: raw.workloadVersion,
                baselineVersion: baselineVersion,
                profile: raw.profile,
                architecture: raw.environment.architecture,
                capabilitySet: raw.capabilitySet
            ),
            referenceMetrics: references,
            reportSHA256: reportSHA256,
            referenceHardware: "Reference Mac",
            frozenAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    func calibrationReportData(
        raw: MacBenchmarkRawResult,
        references: [BenchmarkComponent: Double],
        baselineVersion: String = "baseline-1",
        referenceHardware: String = "Reference Mac",
        frozenAt: Date = Date(timeIntervalSince1970: 2_000)
    ) throws -> Data {
        let report = MacBenchmarkCalibrationReport(
            schemaVersion: 1,
            key: BenchmarkComparisonKey(
                workloadVersion: raw.workloadVersion,
                baselineVersion: baselineVersion,
                profile: raw.profile,
                architecture: raw.environment.architecture,
                capabilitySet: raw.capabilitySet
            ),
            referenceMetrics: references,
            referenceHardware: referenceHardware,
            frozenAt: frozenAt,
            sourceRunSHA256s: (0..<8).map { index in
                MacBenchmarkBaselineVerification.sha256Hex(
                    Data("source-run-\(index)".utf8)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }

    func environmentVariant(
        _ raw: MacBenchmarkRawResult,
        powerSource: BenchmarkPowerSource = .acPower,
        lowPowerModeEnabled: Bool = false,
        thermalState: BenchmarkThermalState = .nominal,
        postflightCapturedAt: Date? = nil,
        diskReliability: BenchmarkDiskReliability = .verified,
        availableDiskBytes: Int64 = 100,
        warnings: [BenchmarkSafetyIssue] = []
    ) -> MacBenchmarkRawResult {
        let completedAt = raw.completedAt!
        return MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: completedAt,
            environment: BenchmarkEnvironmentMetadata(
                architecture: raw.environment.architecture,
                chipName: raw.environment.chipName,
                activeProcessorCount: raw.environment.activeProcessorCount,
                physicalMemoryBytes: raw.environment.physicalMemoryBytes,
                systemDiskCapacityBytes: raw.environment.systemDiskCapacityBytes,
                powerSource: powerSource,
                thermalState: thermalState,
                operatingSystemVersion: raw.environment.operatingSystemVersion,
                appVersion: raw.environment.appVersion,
                appBuild: raw.environment.appBuild
            ),
            preflight: BenchmarkPreflight(
                capturedAt: raw.preflight.capturedAt,
                powerSource: powerSource,
                batteryPercent: raw.preflight.batteryPercent,
                lowPowerModeEnabled: lowPowerModeEnabled,
                thermalState: thermalState,
                diskReliability: diskReliability,
                availableDiskBytes: availableDiskBytes,
                requiredDiskBytes: raw.preflight.requiredDiskBytes,
                warnings: warnings
            ),
            postflight: BenchmarkPostflight(
                capturedAt: postflightCapturedAt ?? completedAt,
                powerSource: powerSource,
                lowPowerModeEnabled: lowPowerModeEnabled,
                thermalState: thermalState,
                diskReliability: diskReliability,
                availableDiskBytes: availableDiskBytes,
                requiredDiskBytes: raw.preflight.requiredDiskBytes,
                warnings: warnings
            ),
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: raw.failure
        )
    }

    func replacingPostflight(
        in raw: MacBenchmarkRawResult,
        with postflight: BenchmarkPostflight
    ) -> MacBenchmarkRawResult {
        MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: raw.environment,
            preflight: raw.preflight,
            postflight: postflight,
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: raw.failure
        )
    }
}
