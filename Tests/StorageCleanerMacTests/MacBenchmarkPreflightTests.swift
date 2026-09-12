import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkPreflightTests: XCTestCase {
    func testNominalACEnvironmentIsReadyForComparableRun() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MacBenchmarkPreflightService(
            now: { capturedAt },
            powerProbe: { (.acPower, 82) },
            lowPowerModeProbe: { false },
            thermalProbe: { .nominal },
            capacityProbe: { 20_000_000_000 },
            diskReliabilityProbe: { .verified }
        )

        let result = try await service.capture(requiredDiskBytes: 3_000_000_000)

        XCTAssertEqual(result.capturedAt, capturedAt)
        XCTAssertEqual(result.powerSource, .acPower)
        XCTAssertEqual(result.batteryPercent, 82)
        XCTAssertEqual(result.diskReliability, .verified)
        XCTAssertTrue(result.hasRequiredDiskCapacity)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(MacBenchmarkPreflightPolicy.blockingIssue(in: result))
        XCTAssertTrue(MacBenchmarkPreflightPolicy.isComparable(result))
    }

    func testPolicyReportsDeterministicActionableSafetyIssues() async throws {
        let service = MacBenchmarkPreflightService(
            powerProbe: { (.battery, 12) },
            lowPowerModeProbe: { true },
            thermalProbe: { .critical },
            capacityProbe: { 1_000 },
            diskReliabilityProbe: { .failing }
        )

        let result = try await service.capture(requiredDiskBytes: 3_000)

        XCTAssertEqual(
            result.warnings,
            [
                .thermalCritical,
                .batteryTooLow,
                .lowPowerModeEnabled,
                .acPowerRequired,
                .diskReliabilityFailing,
                .insufficientDiskCapacity,
            ]
        )
        XCTAssertEqual(MacBenchmarkPreflightPolicy.blockingIssue(in: result), .thermalCritical)
        XCTAssertFalse(MacBenchmarkPreflightPolicy.isComparable(result))
    }

    func testFairAndSeriousThermalStatesAreNotSilentlyScored() async throws {
        for state in [BenchmarkThermalState.fair, .serious] {
            let service = MacBenchmarkPreflightService(
                powerProbe: { (.acPower, 90) },
                lowPowerModeProbe: { false },
                thermalProbe: { state },
                capacityProbe: { 10_000 },
                diskReliabilityProbe: { .verified }
            )

            let result = try await service.capture(requiredDiskBytes: 1_000)

            XCTAssertEqual(result.warnings, [.thermalNotNominal])
            XCTAssertEqual(
                MacBenchmarkPreflightPolicy.blockingIssue(in: result),
                .thermalNotNominal
            )
            XCTAssertFalse(MacBenchmarkPreflightPolicy.isComparable(result))
        }
    }

    func testACDesktopWithoutBatteryCanRunWhenSMARTIsUnavailable() async throws {
        let service = MacBenchmarkPreflightService(
            powerProbe: { (.acPower, nil) },
            lowPowerModeProbe: { false },
            thermalProbe: { .nominal },
            capacityProbe: { 10_000 },
            diskReliabilityProbe: { .unavailable }
        )

        let result = try await service.capture(requiredDiskBytes: 1_000)

        XCTAssertEqual(result.powerSource, .acPower)
        XCTAssertNil(result.batteryPercent)
        XCTAssertEqual(result.diskReliability, .unavailable)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(MacBenchmarkPreflightPolicy.blockingIssue(in: result))
        XCTAssertTrue(MacBenchmarkPreflightPolicy.isComparable(result))
    }

    func testUnknownPowerSourceCannotProduceAComparableScore() async throws {
        let service = MacBenchmarkPreflightService(
            powerProbe: { (.unknown, nil) },
            lowPowerModeProbe: { false },
            thermalProbe: { .nominal },
            capacityProbe: { 10_000 },
            diskReliabilityProbe: { .verified }
        )

        let result = try await service.capture(requiredDiskBytes: 1_000)

        XCTAssertEqual(result.warnings, [.acPowerRequired])
        XCTAssertEqual(
            MacBenchmarkPreflightPolicy.blockingIssue(in: result),
            .acPowerRequired
        )
        XCTAssertFalse(MacBenchmarkPreflightPolicy.isComparable(result))
    }

    func testInvalidRequiredCapacityIsRejectedBeforeAnyProbe() async {
        let counter = LockedCounter()
        let service = MacBenchmarkPreflightService(
            powerProbe: {
                counter.increment()
                return (.acPower, 80)
            },
            lowPowerModeProbe: { false },
            thermalProbe: { .nominal },
            capacityProbe: { 10_000 },
            diskReliabilityProbe: { .verified }
        )

        do {
            _ = try await service.capture(requiredDiskBytes: 0)
            XCTFail("无效空间需求不得启动探测")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkPreflightError, .invalidRequiredDiskBytes)
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testCancellationDoesNotPublishCompletedPreflight() async throws {
        let gate = SuspensionGate<BenchmarkDiskReliability>()
        let service = MacBenchmarkPreflightService(
            powerProbe: { (.acPower, 80) },
            lowPowerModeProbe: { false },
            thermalProbe: { .nominal },
            capacityProbe: { 10_000 },
            diskReliabilityProbe: { try await gate.wait() }
        )

        let task = Task {
            try await service.capture(requiredDiskBytes: 1_000)
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume(returning: .verified)

        do {
            _ = try await task.value
            XCTFail("取消后的探测不得返回成功")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private actor SuspensionGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func wait() async throws -> Value {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resume(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
