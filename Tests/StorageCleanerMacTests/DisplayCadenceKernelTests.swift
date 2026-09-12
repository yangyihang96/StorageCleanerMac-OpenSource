import XCTest
@testable import StorageCleanerMac

final class DisplayCadenceKernelTests: XCTestCase {
    func testFixtureDerivesCadencePercentilesJitterAndEffectiveFPS() async {
        let metadata = DisplayCadenceDeclaredMetadata(
            displayID: 42,
            pixelWidth: 3_840,
            pixelHeight: 2_160,
            logicalWidth: 1_920,
            logicalHeight: 1_080,
            scaleFactor: 2,
            declaredRefreshRateHz: 120,
            isMirrored: false,
            isBuiltin: false
        )
        let provider = FixtureProvider(
            DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: [0, 10, 20, 30, 50, 60],
                hostClockFrequency: 1_000
            )
        )
        let report = await DisplayCadenceKernel(
            configuration: .init(sampleLimit: 6, minimumIntervalCount: 5, timeoutSeconds: 1),
            provider: provider
        ).measure()

        XCTAssertEqual(report.workloadVersion, "display-cadence-v8")
        XCTAssertEqual(report.statisticsVersion, "display-cadence-statistics-v1")
        XCTAssertEqual(report.declaredMetadata, metadata)
        guard case let .measured(metrics) = report.outcome else {
            return XCTFail("fixture should produce cadence metrics")
        }
        XCTAssertEqual(metrics.p50IntervalMilliseconds, 10, accuracy: 0.000_1)
        XCTAssertEqual(metrics.p95IntervalMilliseconds, 18, accuracy: 0.000_1)
        XCTAssertEqual(metrics.p99IntervalMilliseconds, 19.6, accuracy: 0.000_1)
        XCTAssertEqual(metrics.jitterMilliseconds, sqrt(20), accuracy: 0.000_1)
        XCTAssertEqual(metrics.effectiveFramesPerSecond, 83.333_333, accuracy: 0.000_1)
        XCTAssertEqual(metrics.stability, .variable)
    }

    func testMissingAndNonMonotonicTimestampsAreExplicitlyUnavailable() async {
        let provider = FixtureProvider(
            DisplayCadenceSampleBatch(
                declaredMetadata: fixtureMetadata,
                hostTimeTimestamps: [0, 10, 10, 20],
                hostClockFrequency: 1_000
            )
        )
        let report = await DisplayCadenceKernel(
            configuration: .init(sampleLimit: 4, minimumIntervalCount: 3, timeoutSeconds: 1),
            provider: provider
        ).measure()

        guard case let .unavailable(unavailable) = report.outcome else {
            return XCTFail("non-monotonic timestamps must not be silently filtered")
        }
        XCTAssertEqual(unavailable.reason, .nonMonotonicTimestamp)
        XCTAssertEqual(unavailable.capturedTimestampCount, 4)
    }

    func testInsufficientTimestampsAreExplicitlyUnavailable() async {
        let report = await DisplayCadenceKernel(
            configuration: .init(sampleLimit: 4, minimumIntervalCount: 3, timeoutSeconds: 1),
            provider: FixtureProvider(
                DisplayCadenceSampleBatch(
                    declaredMetadata: fixtureMetadata,
                    hostTimeTimestamps: [0, 10, 20],
                    hostClockFrequency: 1_000
                )
            )
        ).measure()

        guard case let .unavailable(unavailable) = report.outcome else {
            return XCTFail("missing callback timestamps must not produce a partial metric")
        }
        XCTAssertEqual(unavailable.reason, .insufficientTimestamps)
        XCTAssertEqual(unavailable.capturedTimestampCount, 3)
    }

    func testProviderUnavailableReasonIsKeptWithoutInventingMetrics() async {
        let report = await DisplayCadenceKernel(
            configuration: .init(sampleLimit: 4, minimumIntervalCount: 3, timeoutSeconds: 1),
            provider: FixtureProvider(
                DisplayCadenceSampleBatch(
                    declaredMetadata: fixtureMetadata,
                    hostTimeTimestamps: [1, 2],
                    hostClockFrequency: 1_000,
                    unavailableReason: .displayChangedDuringCapture
                )
            )
        ).measure()

        guard case let .unavailable(unavailable) = report.outcome else {
            return XCTFail("provider unavailable result must remain explicit")
        }
        XCTAssertEqual(unavailable.reason, .displayChangedDuringCapture)
        XCTAssertEqual(unavailable.capturedTimestampCount, 2)
    }

    func testDifferentDisplayMetadataProducesIndependentExperienceReports() async {
        let secondDisplay = DisplayCadenceDeclaredMetadata(
            displayID: 77,
            pixelWidth: 2_560,
            pixelHeight: 1_440,
            logicalWidth: 2_560,
            logicalHeight: 1_440,
            scaleFactor: 1,
            declaredRefreshRateHz: 60,
            isMirrored: true,
            isBuiltin: false
        )
        let configuration = DisplayCadenceKernel.Configuration(
            sampleLimit: 4,
            minimumIntervalCount: 3,
            timeoutSeconds: 1
        )
        let first = await DisplayCadenceKernel(
            configuration: configuration,
            provider: FixtureProvider(
                DisplayCadenceSampleBatch(
                    declaredMetadata: fixtureMetadata,
                    hostTimeTimestamps: [0, 10, 20, 30],
                    hostClockFrequency: 1_000
                )
            )
        ).measure()
        let second = await DisplayCadenceKernel(
            configuration: configuration,
            provider: FixtureProvider(
                DisplayCadenceSampleBatch(
                    declaredMetadata: secondDisplay,
                    hostTimeTimestamps: [0, 20, 40, 60],
                    hostClockFrequency: 1_000
                )
            )
        ).measure()

        XCTAssertEqual(first.declaredMetadata?.displayID, 42)
        XCTAssertEqual(second.declaredMetadata?.displayID, 77)
        XCTAssertNotEqual(first.declaredMetadata, second.declaredMetadata)
    }

    func testSystemProviderCapturesCadenceOrReportsExplicitUnavailable() async {
        let report = await DisplayCadenceKernel(
            configuration: .init(sampleLimit: 2, minimumIntervalCount: 1, timeoutSeconds: 0.25)
        ).measure()

        switch report.outcome {
        case let .measured(metrics):
            XCTAssertGreaterThan(metrics.effectiveFramesPerSecond, 0)
            XCTAssertGreaterThan(metrics.p50IntervalMilliseconds, 0)
        case let .unavailable(unavailable):
            XCTAssertNotEqual(unavailable.reason, .invalidConfiguration)
        }
    }
}

private extension DisplayCadenceKernelTests {
    var fixtureMetadata: DisplayCadenceDeclaredMetadata {
        DisplayCadenceDeclaredMetadata(
            displayID: 42,
            pixelWidth: 3_840,
            pixelHeight: 2_160,
            logicalWidth: 1_920,
            logicalHeight: 1_080,
            scaleFactor: 2,
            declaredRefreshRateHz: 120,
            isMirrored: false,
            isBuiltin: false
        )
    }
}

private struct FixtureProvider: DisplayCadenceSampleProviding {
    let batch: DisplayCadenceSampleBatch

    init(_ batch: DisplayCadenceSampleBatch) {
        self.batch = batch
    }

    func capture(configuration _: DisplayCadenceKernel.Configuration) async -> DisplayCadenceSampleBatch {
        batch
    }
}
