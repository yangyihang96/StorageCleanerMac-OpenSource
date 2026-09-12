import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacAcceleratorBenchmarkModelsTests: XCTestCase {
    func testMetricCatalogKeepsGPUAndMediaEngineSemanticsSeparate() {
        XCTAssertEqual(MacAcceleratorMetric.allCases.count, 6)
        XCTAssertEqual(MacAcceleratorMetric.metalRaster3D.domain, .gpu)
        XCTAssertEqual(MacAcceleratorMetric.rayTracingBuild.domain, .gpu)
        XCTAssertEqual(MacAcceleratorMetric.rayTracingTraversal.domain, .gpu)
        XCTAssertEqual(MacAcceleratorMetric.gpuTensorFP16.domain, .gpu)
        XCTAssertEqual(MacAcceleratorMetric.mediaH264Encode.domain, .mediaEngine)
        XCTAssertEqual(MacAcceleratorMetric.mediaH264Decode.domain, .mediaEngine)
        XCTAssertEqual(
            MacAcceleratorMetric.gpuTensorFP16.unit,
            .trillionFloatingPointOperationsPerSecond
        )
        XCTAssertEqual(
            MacAcceleratorMetric.mediaH264Encode.unit,
            .megapixelsPerSecond
        )
    }

    func testMeasuredResultRequiresExactlyThreeMatchingDeterministicSamples() {
        let valid = measurement(
            metric: .metalRaster3D,
            values: [98, 100, 102]
        )
        XCTAssertTrue(valid.isValid(expectedSampleCount: 3))
        XCTAssertEqual(valid.medianValue, 100)
        XCTAssertTrue(valid.isStable)

        let wrongCount = measurement(
            metric: .metalRaster3D,
            values: [99, 101]
        )
        XCTAssertFalse(wrongCount.isValid(expectedSampleCount: 3))

        let mismatchedScene = MacAcceleratorMeasurement(
            metric: .metalRaster3D,
            availability: .measured,
            samples: [
                sample(value: 99, checksum: 1),
                sample(value: 100, checksum: 2),
                sample(value: 101, checksum: 1),
            ]
        )
        XCTAssertFalse(mismatchedScene.isValid(expectedSampleCount: 3))

        let zeroDigest = MacAcceleratorMeasurement(
            metric: .metalRaster3D,
            availability: .measured,
            samples: [98, 100, 102].map { sample(value: $0, checksum: 0) }
        )
        XCTAssertFalse(zeroDigest.isValid(expectedSampleCount: 3))
    }

    func testWorkloadFingerprintIsFrozenToCanonicalManifest() {
        XCTAssertEqual(
            MacBenchmarkBaselineVerification.sha256Hex(
                Data(MacAcceleratorBenchmarkResult.workloadManifest.utf8)
            ),
            MacAcceleratorBenchmarkResult.currentWorkloadFingerprint
        )
    }

    func testStabilityThresholdIsRawSignalAndDoesNotInvalidateMeasurement() {
        let unstable = measurement(
            metric: .gpuTensorFP16,
            values: [100, 100, 150]
        )

        XCTAssertTrue(unstable.isValid(expectedSampleCount: 3))
        XCTAssertFalse(unstable.isStable)
        XCTAssertGreaterThan(
            unstable.coefficientOfVariation ?? 0,
            MacAcceleratorMetric.gpuTensorFP16.maximumStableCoefficientOfVariation
        )
    }

    func testUnsupportedAndTemporarilyUnavailableAreStatusNotZeroSamples() {
        for availability in [
            MacAcceleratorAvailability.unsupported,
            .temporarilyUnavailable,
        ] {
            let measurement = MacAcceleratorMeasurement(
                metric: .rayTracingTraversal,
                availability: availability,
                samples: []
            )
            XCTAssertTrue(measurement.isValid(expectedSampleCount: 3))
            XCTAssertNil(measurement.medianValue)
            XCTAssertNil(measurement.coefficientOfVariation)
            XCTAssertFalse(measurement.isStable)
        }

        let forgedZero = MacAcceleratorMeasurement(
            metric: .rayTracingTraversal,
            availability: .unsupported,
            samples: [sample(value: 0, checksum: 1)]
        )
        XCTAssertFalse(forgedZero.isValid(expectedSampleCount: 3))
    }

    func testCompleteResultRequiresEveryMetricExactlyOnce() throws {
        let complete = makeResult()
        XCTAssertTrue(complete.isComplete)
        XCTAssertTrue(complete.isFullyMeasured)
        XCTAssertTrue(complete.hasStableMeasuredSamples)

        let missing = copy(
            complete,
            measurements: Array(complete.measurements.dropLast())
        )
        XCTAssertFalse(missing.isComplete)

        let duplicate = copy(
            complete,
            measurements: complete.measurements + [complete.measurements[0]]
        )
        XCTAssertFalse(duplicate.isComplete)

        let wrongWorkload = MacAcceleratorBenchmarkResult(
            workloadVersion: complete.workloadVersion,
            workloadFingerprint: String(repeating: "0", count: 64),
            startedAt: complete.startedAt,
            completedAt: complete.completedAt,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: complete.postflight,
            measurements: complete.measurements,
            failure: complete.failure
        )
        XCTAssertFalse(wrongWorkload.isComplete)

        let data = try JSONEncoder().encode(complete)
        XCTAssertEqual(
            try JSONDecoder().decode(MacAcceleratorBenchmarkResult.self, from: data),
            complete
        )
    }

    func testCompleteResultCanRetainUnsupportedHardwareWithoutInventingScore() {
        let measured = makeResult()
        let measurements = measured.measurements.map { item in
            guard item.metric == .rayTracingBuild
                    || item.metric == .rayTracingTraversal else { return item }
            return MacAcceleratorMeasurement(
                metric: item.metric,
                availability: .unsupported,
                samples: []
            )
        }
        let result = copy(measured, measurements: measurements)

        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.isFullyMeasured)
        XCTAssertTrue(result.hasStableMeasuredSamples)
        XCTAssertNil(result.measurementsByMetric[.rayTracingTraversal]?.medianValue)
    }
}

private extension MacAcceleratorBenchmarkModelsTests {
    func sample(value: Double, checksum: UInt64 = 0xA11C_E123) -> BenchmarkComponentSample {
        BenchmarkComponentSample(
            value: value,
            elapsedSeconds: 0.25,
            checksum: checksum
        )
    }

    func measurement(
        metric: MacAcceleratorMetric,
        values: [Double]
    ) -> MacAcceleratorMeasurement {
        MacAcceleratorMeasurement(
            metric: metric,
            availability: .measured,
            samples: values.map { sample(value: $0) }
        )
    }

    func makeResult(startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000))
        -> MacAcceleratorBenchmarkResult
    {
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt.addingTimeInterval(1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: MacAcceleratorBenchmarkService.requiredDiskBytes,
            warnings: []
        )
        return MacAcceleratorBenchmarkResult(
            workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(3),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
                systemDiskCapacityBytes: 1_000_000_000_000,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS Test",
                appVersion: "1.0",
                appBuild: "1"
            ),
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(2),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: MacAcceleratorBenchmarkService.requiredDiskBytes,
                warnings: []
            ),
            measurements: MacAcceleratorMetric.allCases.enumerated().map { index, metric in
                measurement(
                    metric: metric,
                    values: [
                        Double(index + 1) * 100 - 1,
                        Double(index + 1) * 100,
                        Double(index + 1) * 100 + 1,
                    ]
                )
            },
            failure: nil
        )
    }

    func copy(
        _ result: MacAcceleratorBenchmarkResult,
        measurements: [MacAcceleratorMeasurement]
    ) -> MacAcceleratorBenchmarkResult {
        MacAcceleratorBenchmarkResult(
            workloadVersion: result.workloadVersion,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            environment: result.environment,
            preflight: result.preflight,
            postflight: result.postflight,
            measurements: measurements,
            failure: result.failure
        )
    }
}
