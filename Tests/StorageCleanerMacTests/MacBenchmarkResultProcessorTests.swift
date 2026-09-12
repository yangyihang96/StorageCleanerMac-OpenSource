import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkResultProcessorTests: XCTestCase {
    func testMatchingVerifiedBaselineProducesScoredResult() throws {
        let raw = makeRawResult()
        let baseline = try makeVerifiedBaseline(for: raw)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: [baseline]
        )

        let processed = try MacBenchmarkResultProcessor(
            baselineCatalog: catalog
        ).process(raw)

        XCTAssertNil(processed.rawOnlyReason)
        XCTAssertEqual(try XCTUnwrap(processed.result.overallScore), 6_000)
        XCTAssertEqual(
            Set(processed.result.componentScores.keys),
            Set(BenchmarkComponent.allCases)
        )
    }

    func testMissingVerifiedBaselinePreservesRawMetricsWithoutInventingScore() throws {
        let raw = makeRawResult()
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )

        let processed = try MacBenchmarkResultProcessor(
            baselineCatalog: catalog
        ).process(raw)

        XCTAssertEqual(processed.rawOnlyReason, .verifiedBaselineUnavailable)
        XCTAssertTrue(processed.result.isComplete)
        XCTAssertNil(processed.result.overallScore)
        XCTAssertTrue(processed.result.componentScores.isEmpty)
        XCTAssertEqual(processed.result.rawResult, raw)
    }

    func testUnsupportedArchitectureHasDistinctRawOnlyReason() throws {
        let raw = makeRawResult(architecture: .x86_64)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )

        let processed = try MacBenchmarkResultProcessor(
            baselineCatalog: catalog
        ).process(raw)

        XCTAssertEqual(processed.rawOnlyReason, .unsupportedArchitecture)
        XCTAssertNil(processed.result.overallScore)
    }

    func testUnstableV6MeasurementsRemainRawOnlyWithOrWithoutBaseline() throws {
        let raw = makeRawResult(
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            profile: .standard,
            samplesByComponent: [.cpuSingle: [80, 100, 120]]
        )
        let baseline = try makeVerifiedBaseline(for: raw)
        let matchedCatalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: [baseline]
        )
        let missingCatalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )

        for catalog in [matchedCatalog, missingCatalog] {
            let processed = try MacBenchmarkResultProcessor(
                baselineCatalog: catalog
            ).process(raw)
            XCTAssertEqual(processed.rawOnlyReason, .unstableSamples)
            XCTAssertEqual(processed.result.rawResult, raw)
            XCTAssertNil(processed.result.overallScore)
            XCTAssertTrue(processed.result.componentScores.isEmpty)
        }
    }

    func testAmbiguousBaselinePreservesRawMetricsWithExplicitReason() throws {
        let raw = makeRawResult()
        let baseline = try makeVerifiedBaseline(for: raw)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: [baseline, baseline]
        )

        let processed = try MacBenchmarkResultProcessor(
            baselineCatalog: catalog
        ).process(raw)

        XCTAssertEqual(processed.rawOnlyReason, .ambiguousBaseline)
        XCTAssertEqual(processed.result.rawResult, raw)
        XCTAssertNil(processed.result.overallScore)
    }

    func testFutureWorkloadWithMatchingBaselineNeverFallsBackToOldFormula() throws {
        let raw = makeRawResult(
            workloadVersion: "mac-benchmark-standard-v7",
            profile: .standard
        )
        let baseline = try makeVerifiedBaseline(for: raw)
        let processor = MacBenchmarkResultProcessor(
            baselineCatalog: try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "m5-pro-v1",
                verifiedBaselines: [baseline]
            )
        )

        let processed = try processor.process(raw)

        XCTAssertEqual(processed.rawOnlyReason, .unsupportedWorkloadVersion)
        XCTAssertNil(processed.result.overallScore)
        XCTAssertEqual(processed.result.rawResult, raw)
    }

    func testPersistedSampleCountAndChecksumContractFailsClosed() throws {
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )
        let processor = MacBenchmarkResultProcessor(baselineCatalog: catalog)
        let oneSampleStandard = makeRawResult(
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            profile: .standard,
            samplesByComponent: [.cpuSingle: [100]]
        )
        let threeSampleFull = makeRawResult(
            workloadVersion: "mac-benchmark-full-v3",
            profile: .full,
            samplesByComponent: [.memory: [100, 100, 100]]
        )
        let valid = makeRawResult()
        let mixedChecksum = replacingFirstComponent(in: valid) { measurement in
            BenchmarkComponentMeasurement(
                component: measurement.component,
                unit: measurement.unit,
                samples: measurement.samples.enumerated().map { index, sample in
                    BenchmarkComponentSample(
                        value: sample.value,
                        elapsedSeconds: sample.elapsedSeconds,
                        checksum: index == 2 ? sample.checksum + 1 : sample.checksum
                    )
                }
            )
        }

        for raw in [oneSampleStandard, threeSampleFull, mixedChecksum] {
            let processed = try processor.process(raw)
            XCTAssertEqual(processed.rawOnlyReason, .invalidSampleContract)
            XCTAssertNil(processed.result.overallScore)
        }
    }

    func testImplausibleV6RatioRetainsRawMetricsInsteadOfClamping() throws {
        let raw = makeRawResult(
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            profile: .standard,
            samplesByComponent: [.cpuSingle: [1, 1, 1]]
        )
        let baseline = try makeVerifiedBaseline(for: raw)
        let processor = MacBenchmarkResultProcessor(
            baselineCatalog: try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "m5-pro-v1",
                verifiedBaselines: [baseline]
            )
        )

        let processed = try processor.process(raw)

        XCTAssertEqual(processed.rawOnlyReason, .implausiblePerformanceRatio)
        XCTAssertNil(processed.result.overallScore)
        XCTAssertEqual(processed.result.rawResult, raw)
    }

    func testProcessorExposesWhetherItsActiveCatalogIsActuallyVerified() throws {
        let raw = makeRawResult()
        let verified = try makeVerifiedBaseline(for: raw)
        let matched = MacBenchmarkResultProcessor(
            baselineCatalog: try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "m5-pro-v1",
                verifiedBaselines: [verified]
            )
        )
        let rawOnly = MacBenchmarkResultProcessor(
            baselineCatalog: .rawOnly(activeBaselineVersion: "m5-pro-v1")
        )

        XCTAssertTrue(matched.hasVerifiedActiveBaseline)
        XCTAssertFalse(rawOnly.hasVerifiedActiveBaseline)
    }

    func testFailedOrIncompleteRawResultNeverReachesScoringOrHistoryPipeline() throws {
        let complete = makeRawResult()
        let incomplete = MacBenchmarkRawResult(
            profile: complete.profile,
            workloadVersion: complete.workloadVersion,
            startedAt: complete.startedAt,
            completedAt: nil,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: nil,
            capabilitySet: complete.capabilitySet,
            measurements: complete.measurements,
            failure: .cancelled
        )
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )

        XCTAssertThrowsError(
            try MacBenchmarkResultProcessor(
                baselineCatalog: catalog
            ).process(incomplete)
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkResultProcessingError,
                .incompleteRawResult
            )
        }
    }

    private func makeRawResult(
        architecture: BenchmarkArchitecture = .arm64,
        workloadVersion: String = "mac-benchmark-quick-v3",
        profile: BenchmarkProfile = .quick,
        samplesByComponent: [BenchmarkComponent: [Double]] = [:]
    ) -> MacBenchmarkRawResult {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = BenchmarkComponent.allCases.map { component in
            let values = samplesByComponent[component]
                ?? Array(repeating: 100, count: profile == .full ? 5 : 3)
            return BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit(for: profile),
                samples: values.enumerated().map { index, value in
                    BenchmarkComponentSample(
                        value: value,
                        elapsedSeconds: 1 + Double(index) / 10,
                        checksum: UInt64(component.rawValue.count)
                    )
                }
            )
        }
        return MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(10),
            environment: BenchmarkEnvironmentMetadata(
                architecture: architecture,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 16_000_000_000,
                systemDiskCapacityBytes:
                    MacBenchmarkScoring.referenceSystemDiskCapacityBytes,
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
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(9),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
    }

    private func makeVerifiedBaseline(
        for raw: MacBenchmarkRawResult
    ) throws -> VerifiedMacBenchmarkBaseline {
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "m5-pro-v1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let metrics = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 100.0) }
        )
        let frozenAt = Date(timeIntervalSince1970: 1_800_000_500)
        let report = MacBenchmarkCalibrationReport(
            schemaVersion: MacBenchmarkCalibrationReport.currentSchemaVersion,
            key: key,
            referenceMetrics: metrics,
            referenceHardware: "Apple M5 Pro reference",
            frozenAt: frozenAt,
            sourceRunSHA256s: [
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-1".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-2".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-3".utf8)),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        return try VerifiedMacBenchmarkBaseline(
            baseline: MacBenchmarkBaseline(
                comparisonKey: key,
                referenceMetrics: metrics,
                reportSHA256: MacBenchmarkBaselineVerification.sha256Hex(data),
                referenceHardware: report.referenceHardware,
                frozenAt: frozenAt
            ),
            calibrationReport: data
        )
    }

    private func replacingFirstComponent(
        in raw: MacBenchmarkRawResult,
        transform: (BenchmarkComponentMeasurement) -> BenchmarkComponentMeasurement
    ) -> MacBenchmarkRawResult {
        var transformed = false
        let measurements = raw.measurements.map { measurement in
            guard !transformed else { return measurement }
            transformed = true
            return transform(measurement)
        }
        return MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: raw.environment,
            preflight: raw.preflight,
            postflight: raw.postflight,
            capabilitySet: raw.capabilitySet,
            measurements: measurements,
            failure: raw.failure
        )
    }
}
