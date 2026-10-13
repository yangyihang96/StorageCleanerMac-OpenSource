import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MSeriesV11TelemetryBridgeTests: XCTestCase {
    func testDelayedObservationCannotCrossSessionsAndFinishClearsPresentation() {
        let monitor = HelperPowerMetricsMonitor(availability: { .needsHelper }, request: {
            XCTFail("the synthetic session test must not sample the real helper"); return .failure(.unavailable)
        }, automaticSampling: false)
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor)
        let first = UUID(), second = UUID()
        func value(_ session: UUID) -> MSeriesV11LiveObservation {
            .init(sessionID: session, stageID: "power.cpu.allCores", endedAtNanoseconds: 10,
                efficiency: 50, unit: "fixed-fixtures/J", observedSeconds: 5)
        }
        bridge.beginSession(sessionID: first); bridge.present(value(first))
        XCTAssertEqual(bridge.liveObservation?.sessionID, first)
        bridge.finish()
        XCTAssertNil(bridge.liveObservation)
        bridge.present(value(first))
        XCTAssertNil(bridge.liveObservation)
        bridge.beginSession(sessionID: second)
        bridge.present(value(first))
        XCTAssertNil(bridge.liveObservation, "a suspended old callback must not publish into a new session")
        bridge.present(value(second))
        XCTAssertEqual(bridge.liveObservation?.sessionID, second)
        bridge.reset()
        bridge.present(value(second))
        XCTAssertNil(bridge.liveObservation)
        bridge.finish()
        XCTAssertFalse(monitor.hasDemand)
    }

    func testLegacyWireReplyPreservesNumbersWithoutInventingMeasurementTimes() throws {
        let legacy = Data("""
        {"cpuMilliwatts":5000,"gpuMilliwatts":2000,"aneMilliwatts":0,"durationSeconds":1,
         "clusters":[{"name":"P0","kind":"performance","megahertz":3200}],"gpuMegahertz":800}
        """.utf8)
        let sample = try JSONDecoder().decode(PowermetricsSample.self, from: legacy)
        XCTAssertTrue(sample.isValid)
        XCTAssertNil(sample.timing)
        let converted = MSeriesV11TelemetryBridge.convert(bracket(sample))
        XCTAssertEqual(converted.telemetry.timestampQuality, "requestBracketOnly")
        XCTAssertNil(converted.telemetry.measurementStartMonotonicNs)
        XCTAssertNil(converted.telemetry.measurementEndMonotonicNs)
        XCTAssertEqual(converted.telemetry.helperBootID, "", "unknown helper identity stays unknown")
        XCTAssertTrue(converted.telemetry.sampleID.hasPrefix("request:"))
        XCTAssertEqual(converted.telemetry.cpuMilliwatts, 5_000)
        XCTAssertEqual(converted.telemetry.aneMilliwatts, 0)
        XCTAssertEqual(converted.clusters, sample.clusters)
        XCTAssertEqual(converted.gpuMegahertz, 800)
        XCTAssertTrue(converted.missingReasons.contains("legacyHelperTimingMissing"))
    }

    func testCommandLifecycleAndElapsedDurationNeverBecomeMeasurementProof() throws {
        let sample = self.sample.withTiming(timing(quality: .requestBracketOnly,
                                             start: 100_100_000_000, end: 101_100_000_000))
        XCTAssertEqual(try JSONDecoder().decode(PowermetricsSample.self, from: JSONEncoder().encode(sample)), sample)
        let converted = MSeriesV11TelemetryBridge.convert(bracket(sample))
        XCTAssertEqual(converted.telemetry.timestampQuality, "requestBracketOnly")
        XCTAssertNil(converted.telemetry.measurementStartMonotonicNs)
        XCTAssertNil(converted.telemetry.measurementEndMonotonicNs)
        XCTAssertEqual(converted.telemetry.durationSeconds, 1)
        XCTAssertEqual(converted.telemetry.sampleID, sample.timing?.sampleID)
        XCTAssertEqual(converted.telemetry.helperBootID, sample.timing?.helperBootID)
        XCTAssertTrue(converted.missingReasons.contains("helperMeasurementIntervalUnavailable"))
    }

    func testVerifiedSameDomainIntervalIsAcceptedAndMalformedIntervalsDegrade() {
        let verified = MSeriesV11TelemetryBridge.convert(bracket(sample.withTiming(timing())))
        XCTAssertEqual(verified.telemetry.timestampQuality, "helperMeasured")
        XCTAssertEqual(verified.telemetry.measurementStartMonotonicNs, 100_100_000_000)
        XCTAssertEqual(verified.telemetry.measurementEndMonotonicNs, 101_100_000_000)
        XCTAssertTrue(verified.missingReasons.isEmpty)

        let rejected = [
            timing(start: 101_100_000_000, end: 100_100_000_000),
            timing(start: 99_100_000_000, end: 100_100_000_000),
            timing(start: 100_500_000_000, end: 101_500_000_000),
            timing(start: 100_100_000_000, end: 100_100_000_000),
            timing(start: 100_100_000_000, end: 100_900_000_000),
            timing(start: nil, end: nil),
            timing(domain: "process-origin-v1"),
        ]
        for evidence in rejected {
            let converted = MSeriesV11TelemetryBridge.convert(bracket(sample.withTiming(evidence)))
            XCTAssertEqual(converted.telemetry.timestampQuality, "requestBracketOnly", "\(evidence)")
            XCTAssertNil(converted.telemetry.measurementStartMonotonicNs)
            XCTAssertNil(converted.telemetry.measurementEndMonotonicNs)
            XCTAssertEqual(converted.telemetry.cpuMilliwatts, 5_000, "diagnostic power survives evidence downgrade")
            XCTAssertTrue(converted.missingReasons.contains("helperMeasurementIntervalInvalid"))
        }
    }

    func testNonmonotonicOrUnknownRequestClockRemainsUntimed() {
        for reading in [
            HelperPowerMetricsReading(sample: sample, requestStartMonotonicNs: 100, responseReceivedMonotonicNs: 99,
                                      clockDomain: "mach-continuous-v1"),
            HelperPowerMetricsReading(sample: sample, requestStartMonotonicNs: 100, responseReceivedMonotonicNs: 100,
                                      clockDomain: "mach-continuous-v1"),
            HelperPowerMetricsReading(sample: sample, requestStartMonotonicNs: 100, responseReceivedMonotonicNs: 101,
                                      clockDomain: "unknown"),
        ] {
            let converted = MSeriesV11TelemetryBridge.convert(reading)
            XCTAssertEqual(converted.telemetry.timestampQuality, "legacyUntimed")
            XCTAssertNil(converted.telemetry.measurementStartMonotonicNs)
            XCTAssertTrue(converted.missingReasons.contains("requestClockInvalid"))
        }
    }

    func testBridgeSharesDemandAndHiddenBridgeDoesNotCollectOtherConsumersReadings() async {
        let nanos = Box<UInt64>(100_000_000_000), time = Box(100.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1; nanos.value += 1_000_000_000
            return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false, monotonicNanoseconds: { nanos.value })
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor, now: { nanos.value })
        bridge.beginSession()
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 0, "creating an observer cannot start telemetry")
        let sensors = UUID()
        monitor.updateConsumer(sensors, visible: true)
        await monitor.sampleIfDue()
        XCTAssertTrue(bridge.readings.isEmpty)
        time.value = 102; nanos.value = 102_000_000_000
        bridge.setVisible(true)
        await monitor.sampleIfDue()
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2, "both consumers share the same throttle")
        XCTAssertEqual(bridge.readings.count, 1)
        bridge.setVisible(false)
        XCTAssertTrue(monitor.hasDemand, "other consumers retain their demand")
        time.value = 104; nanos.value = 104_000_000_000
        await monitor.sampleIfDue()
        XCTAssertEqual(bridge.readings.count, 1)
        XCTAssertTrue(bridge.missingReasons.contains("telemetryNotVisible"))
        monitor.updateConsumer(sensors, visible: false)
        time.value = 106
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 3, "no consumers means no further requests")
        bridge.finish()
    }

    func testBridgeIgnoresRequestStartedBeforeItsVisibilityWhileOtherDemandRemains() async {
        let nanos = Box<UInt64>(100_000_000_000)
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            await withCheckedContinuation { gate.value = $0 }
        }, automaticSampling: false, monotonicNanoseconds: { nanos.value })
        let sensors = UUID()
        monitor.updateConsumer(sensors, visible: true)
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor, now: { nanos.value })
        bridge.beginSession()
        let pending = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 {
            if gate.value != nil { break }
            await Task.yield()
        }
        guard let continuation = gate.value else {
            pending.cancel(); monitor.updateConsumer(sensors, visible: false)
            await pending.value
            return XCTFail("request did not enter gate")
        }
        nanos.value = 100_500_000_000
        bridge.setVisible(true)
        nanos.value = 101_200_000_000
        continuation.resume(returning: .sample(sample))
        await pending.value
        XCTAssertNotNil(monitor.latestReading)
        XCTAssertTrue(bridge.readings.isEmpty, "a new consumer cannot import a previous visibility interval")
        bridge.finish()
        monitor.updateConsumer(sensors, visible: false)
    }

    func testDuplicateSampleIdentityIsNotCountedTwiceAndBudgetOverflowIsExplicit() async {
        let nanos = Box<UInt64>(100_000_000_000), time = Box(100.0)
        let result = Box(sample.withTiming(timing(quality: .requestBracketOnly)))
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            nanos.value += 1_000_000_000; return .sample(result.value)
        }, now: { time.value }, automaticSampling: false, monotonicNanoseconds: { nanos.value })
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor, maximumSamples: 1, now: { nanos.value })
        bridge.beginSession()
        bridge.setVisible(true)
        await monitor.sampleIfDue()
        time.value = 102; nanos.value = 102_000_000_000
        await monitor.sampleIfDue()
        XCTAssertEqual(bridge.readings.count, 1)
        XCTAssertFalse(bridge.overflowed, "a joined/duplicate sample is not an independent measurement")
        result.value = sample.withTiming(timing(quality: .requestBracketOnly))
        time.value = 104; nanos.value = 104_000_000_000
        await monitor.sampleIfDue()
        XCTAssertTrue(bridge.overflowed)
        XCTAssertTrue(bridge.missingReasons.contains("telemetryLimitExceeded"))
        XCTAssertEqual(bridge.readings.count, 1)
        bridge.reset()
        XCTAssertTrue(bridge.readings.isEmpty)
        XCTAssertFalse(bridge.overflowed)
        XCTAssertTrue(bridge.isCollecting)
        time.value = 106; nanos.value = 106_000_000_000
        await monitor.sampleIfDue()
        XCTAssertEqual(bridge.readings.count, 1, "reset clears previous evidence and sample-identity cache")
        bridge.finish()
        XCTAssertFalse(monitor.hasDemand)
    }

    func testNewSessionRejectsPreviousInFlightReplyEvenAtSameClockTick() async {
        let nanos = Box<UInt64>(100_000_000_000), time = Box(100.0), calls = Box(0)
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            if calls.value == 2 { return await withCheckedContinuation { gate.value = $0 } }
            nanos.value += 1_000_000_000
            return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false, monotonicNanoseconds: { nanos.value })
        let sensors = UUID()
        monitor.updateConsumer(sensors, visible: true)
        let bridge = MSeriesV11TelemetryBridge(monitor: monitor, now: { nanos.value })
        bridge.setVisible(true)
        XCTAssertFalse(bridge.isCollecting, "page visibility alone is not a run")
        bridge.beginSession()
        await monitor.sampleIfDue()
        XCTAssertEqual(bridge.readings.count, 1)
        time.value = 102; nanos.value = 102_000_000_000
        let pending = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 {
            if gate.value != nil { break }
            await Task.yield()
        }
        guard let continuation = gate.value else {
            pending.cancel(); bridge.finish(); monitor.updateConsumer(sensors, visible: false)
            await pending.value
            return XCTFail("request did not enter gate")
        }
        bridge.finish()
        XCTAssertTrue(bridge.isVisible, "finish releases the run lease, not the surface visibility")
        bridge.beginSession()
        XCTAssertTrue(bridge.readings.isEmpty)
        nanos.value = 103_000_000_000
        continuation.resume(returning: .sample(sample))
        await pending.value
        XCTAssertTrue(bridge.readings.isEmpty, "the old request sequence cannot enter a new run")
        time.value = 104; nanos.value = 104_000_000_000
        await monitor.sampleIfDue()
        XCTAssertEqual(bridge.readings.count, 1)
        bridge.finish()
        XCTAssertTrue(monitor.hasDemand)
        monitor.updateConsumer(sensors, visible: false)
        XCTAssertFalse(monitor.hasDemand)
    }

    private func bracket(_ sample: PowermetricsSample) -> HelperPowerMetricsReading {
        .init(sample: sample, requestStartMonotonicNs: 100_000_000_000, responseReceivedMonotonicNs: 101_200_000_000,
              clockDomain: "mach-continuous-v1")
    }

    private func timing(quality: PowermetricsSample.Timing.Quality = .helperMeasured,
                        start: UInt64? = 100_100_000_000, end: UInt64? = 101_100_000_000,
                        domain: String = "mach-continuous-v1") -> PowermetricsSample.Timing {
        .init(sampleID: UUID().uuidString, helperBootID: UUID().uuidString, clockDomain: domain,
              measurementStartMonotonicNs: start, measurementEndMonotonicNs: end, timestampQuality: quality)
    }

    private var sample: PowermetricsSample {
        .init(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
              clusters: [.init(name: "P0", kind: .performance, megahertz: 3_200)], gpuMegahertz: 800, durationSeconds: 1)
    }

    @MainActor
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
