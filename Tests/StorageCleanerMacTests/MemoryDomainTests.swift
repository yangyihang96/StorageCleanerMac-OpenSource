import XCTest
@testable import StorageCleanerMac

final class MemoryDomainTests: XCTestCase {
    func testPressureClassificationPrioritizesCriticalSignals() {
        XCTAssertEqual(
            MemoryPressurePolicy.classify(
                physicalBytes: 16_000,
                availableBytes: 500,
                compressedBytes: 1_000,
                swapUsedBytes: 0,
                pressureFreePercentage: 10
            ),
            .critical
        )
        XCTAssertEqual(
            MemoryPressurePolicy.classify(pressureFreePercentage: 15),
            .elevated
        )
        XCTAssertEqual(
            MemoryPressurePolicy.classify(pressureFreePercentage: 70),
            .normal
        )
    }

    func testUnavailableMeasurementsRemainUnavailableInDerivedUsage() {
        let snapshot = makeSnapshot(
            available: .unavailable(
                .permissionDenied,
                reason: "Permission was revoked."
            )
        )

        XCTAssertNil(snapshot.measuredUsedBytes)
        XCTAssertNil(snapshot.measuredUsedRatio)
        XCTAssertTrue(
            snapshot.measurements.availableBytes.unavailableDetail?
                .contains("Permission was revoked") == true
        )
    }

    func testSwapRatesUseMonotonicElapsedTimeAndRejectCounterRollback() async {
        let clock = ContinuousClock()
        let start = clock.now
        let history = MemoryHistoryStore()

        let first = await history.rates(
            instant: start,
            pageIns: 100,
            pageOuts: 200,
            pageSize: 4_096
        )
        let second = await history.rates(
            instant: start.advanced(by: .seconds(2)),
            pageIns: 104,
            pageOuts: 206,
            pageSize: 4_096
        )
        let rollback = await history.rates(
            instant: start.advanced(by: .seconds(3)),
            pageIns: 1,
            pageOuts: 1,
            pageSize: 4_096
        )

        XCTAssertNil(first.swapIn)
        XCTAssertNil(first.swapOut)
        XCTAssertEqual(second.swapIn ?? -1, 8_192, accuracy: 0.001)
        XCTAssertEqual(second.swapOut ?? -1, 12_288, accuracy: 0.001)
        XCTAssertNil(rollback.swapIn)
        XCTAssertNil(rollback.swapOut)
    }

    func testRingCompositionIgnoresOversizedOrMissingAppMeasurement() throws {
        let oversizedApp = makeSnapshot(
            available: .available(2_000),
            app: .available(80_000),
            wired: .available(3_000),
            compressed: .available(1_000)
        )
        let missingApp = makeSnapshot(
            available: .available(2_000),
            app: .unavailable(.temporarilyInvalid, reason: "Process scan skipped."),
            wired: .available(3_000),
            compressed: .available(1_000)
        )

        let composition = try XCTUnwrap(oversizedApp.ringComposition)
        XCTAssertEqual(composition, missingApp.ringComposition)
        XCTAssertEqual(composition.physicalBytes, 8_000)
        XCTAssertEqual(composition.availableBytes, 2_000)
        XCTAssertEqual(composition.usedBytes, 6_000)
        XCTAssertEqual(composition.wiredBytes, 3_000)
        XCTAssertEqual(composition.compressedBytes, 1_000)
        XCTAssertEqual(composition.appOrOtherBytes, 2_000)
        XCTAssertEqual(composition.availableRatio, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(composition.usedRatio, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(composition.wiredRatio, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(composition.compressedRatio, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(composition.appOrOtherRatio, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(
            composition.wiredRatio
                + composition.compressedRatio
                + composition.appOrOtherRatio,
            composition.usedRatio,
            accuracy: 0.000_001
        )
    }

    func testRingCompositionClampsWiredAndCompressedToUsedBudget() throws {
        let snapshot = makeSnapshot(
            physical: .available(100),
            available: .available(20),
            wired: .available(60),
            compressed: .available(50)
        )

        let composition = try XCTUnwrap(snapshot.ringComposition)
        XCTAssertEqual(composition.usedBytes, 80)
        XCTAssertEqual(composition.wiredBytes, 60)
        XCTAssertEqual(composition.compressedBytes, 20)
        XCTAssertEqual(composition.appOrOtherBytes, 0)
        XCTAssertEqual(composition.usedRatio, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(composition.wiredRatio, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(composition.compressedRatio, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(composition.appOrOtherRatio, 0, accuracy: 0.000_001)
    }

    func testRingCompositionClampsAvailableToPhysicalAndLeavesFullTrackGap() throws {
        let snapshot = makeSnapshot(
            physical: .available(100),
            available: .available(150),
            wired: .available(90),
            compressed: .available(90)
        )

        let composition = try XCTUnwrap(snapshot.ringComposition)
        XCTAssertEqual(composition.availableBytes, 100)
        XCTAssertEqual(composition.usedBytes, 0)
        XCTAssertEqual(composition.wiredBytes, 0)
        XCTAssertEqual(composition.compressedBytes, 0)
        XCTAssertEqual(composition.appOrOtherBytes, 0)
        XCTAssertEqual(composition.availableRatio, 1, accuracy: 0.000_001)
        XCTAssertEqual(composition.usedRatio, 0, accuracy: 0.000_001)
    }

    func testRingCompositionRequiresPositivePhysicalAndEverySystemMeasurement() {
        XCTAssertNil(makeSnapshot(
            physical: .available(0),
            available: .available(0)
        ).ringComposition)
        XCTAssertNil(makeSnapshot(
            physical: .unavailable(.temporarilyInvalid, reason: "Missing physical memory."),
            available: .available(1)
        ).ringComposition)
        XCTAssertNil(makeSnapshot(
            physical: MemoryMeasurement(
                value: 8_000,
                availability: .temporarilyInvalid,
                reason: "Stale physical memory."
            ),
            available: .available(2_000)
        ).ringComposition)
        XCTAssertNil(makeSnapshot(
            available: .unavailable(.temporarilyInvalid, reason: "Missing available memory.")
        ).ringComposition)
        XCTAssertNil(makeSnapshot(
            available: .available(2_000),
            wired: .unavailable(.temporarilyInvalid, reason: "Missing wired memory.")
        ).ringComposition)
        XCTAssertNil(makeSnapshot(
            available: .available(2_000),
            compressed: .unavailable(.temporarilyInvalid, reason: "Missing compressed memory.")
        ).ringComposition)
    }

    private func makeSnapshot(
        physical: MemoryMeasurement<UInt64> = .available(8_000),
        available: MemoryMeasurement<UInt64>,
        app: MemoryMeasurement<UInt64> = .available(2_000),
        wired: MemoryMeasurement<UInt64> = .available(1_000),
        compressed: MemoryMeasurement<UInt64> = .available(500)
    ) -> MemorySnapshot {
        MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: Int64(clamping: physical.value ?? 0),
            freeBytes: 0,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: Int64(clamping: wired.value ?? 0),
            compressedBytes: Int64(clamping: compressed.value ?? 0),
            swapUsedBytes: 0,
            pressureFreePercentage: nil,
            pressureSummary: "Unavailable",
            topProcesses: [],
            measurements: MemoryMeasurements(
                pressure: .unavailable(.temporarilyInvalid, reason: "Unavailable"),
                physicalBytes: physical,
                availableBytes: available,
                appBytes: app,
                wiredBytes: wired,
                compressedBytes: compressed,
                cachedBytes: .available(1_000),
                swapUsedBytes: .unavailable(.permissionDenied, reason: "Unavailable"),
                swapInRate: .unavailable(.temporarilyInvalid, reason: "Unavailable"),
                swapOutRate: .unavailable(.temporarilyInvalid, reason: "Unavailable")
            ),
            quality: .partial
        )
    }
}
