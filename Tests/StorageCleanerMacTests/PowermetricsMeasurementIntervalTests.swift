import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// Synthetic native-shape contract fixtures, never claimed as host recordings.
final class PowermetricsMeasurementIntervalTests: XCTestCase {
    private let boot = "B26B1111-2222-4333-8444-555555555555"
    private let launchNs: UInt64 = 100_000_000_000
    private let launchWall = Date(timeIntervalSinceReferenceDate: 1_000.125)

    private func anchor(_ ns: UInt64, _ wall: Date) -> PowermetricsMeasurementContext.Anchor {
        .init(beforeMonotonicNs: ns, wallTime: wall, afterMonotonicNs: ns)
    }

    private func context(end: Double = 1.2, wallStep: Double = 0) -> PowermetricsMeasurementContext {
        .init(launched: anchor(launchNs, launchWall),
              finished: anchor(launchNs + UInt64(end * 1e9), launchWall.addingTimeInterval(end + wallStep)),
              helperBootID: boot)
    }

    private func root(offset: Double = 1.125) -> [String: Any] {
        ["elapsed_ns": 1_000_000_000, "is_delta": true,
         "timestamp": launchWall.addingTimeInterval(offset).timeIntervalSince1970,
         "processor": ["cpu_power": 2_000, "gpu_power": 4_000, "ane_power": 0]]
    }

    private func data(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0) + Data([0])
    }

    private func parse(_ root: [String: Any], _ context: PowermetricsMeasurementContext? = nil) throws -> PowermetricsSample {
        try PowermetricsPlistParser.parse(data(root), measurementContext: context ?? self.context())
    }

    func testNativeEndAndStartBoundaryResolveOnlyInsideChildLifecycle() throws {
        for (offset, source) in [(1.125, "nativeTimestampEnd+elapsed_ns"), (0.125, "nativeTimestampStart+elapsed_ns")] {
            let sample = try parse(root(offset: offset))
            let timing = try XCTUnwrap(sample.timing)
            XCTAssertEqual(timing.timestampQuality, .helperMeasured)
            XCTAssertEqual(Double(try XCTUnwrap(timing.measurementStartMonotonicNs)), 100_125_000_000, accuracy: 1_000)
            XCTAssertEqual(Double(try XCTUnwrap(timing.measurementEndMonotonicNs)), 101_125_000_000, accuracy: 1_000)
            XCTAssertEqual(timing.helperProcessStartMonotonicNs, launchNs)
            XCTAssertEqual(timing.helperProcessEndMonotonicNs, 101_200_000_000)
            XCTAssertEqual(timing.timestampSource, source)
            XCTAssertEqual(timing.helperBootID, boot)
            XCTAssertNotNil(UUID(uuidString: timing.sampleID))
            XCTAssertEqual(timing.clockDomain, MSeriesV11Windows.clockDomain)
            XCTAssertEqual(sample.durationSeconds, 1)
        }
        let first = try parse(root()), second = try parse(root())
        XCTAssertNotEqual(first.timing?.sampleID, second.timing?.sampleID)
        XCTAssertEqual(first.timing?.helperBootID, second.timing?.helperBootID)
    }

    func testMissingNativeTimingRetainsDiagnosticNumbersWithoutInventingInterval() throws {
        for key in ["timestamp", "is_delta"] {
            var value = root(); value.removeValue(forKey: key)
            let sample = try parse(value)
            assertBracket(sample)
            XCTAssertEqual(sample.cpuMilliwatts, 2_000)
            XCTAssertEqual(sample.aneMilliwatts, 0)
        }
        let elapsedOnly = try parse(["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 2_000]])
        assertBracket(elapsedOnly)
        var missingElapsed = root(); missingElapsed.removeValue(forKey: "elapsed_ns")
        XCTAssertThrowsError(try parse(missingElapsed), "without duration the power DTO itself is invalid")
    }

    func testUntrustedTimestampKindsWholeSecondsAndDeltaMarkersDegrade() throws {
        for timestamp: Any in [true, 1_001, "2001-01-01T00:16:41.225Z", Date(timeIntervalSinceReferenceDate: 1_001),
                              launchWall.addingTimeInterval(1.125).timeIntervalSince1970 * 1e9] {
            var value = root(); value["timestamp"] = timestamp
            assertBracket(try parse(value))
        }
        for delta: Any in [false, 1, "true"] {
            var value = root(); value["is_delta"] = delta
            assertBracket(try parse(value))
        }
        var fraction = root(); fraction["elapsed_ns"] = 1_000_000_000.5
        assertBracket(try parse(fraction))
        // Default Foundation XML Date serialization loses subsecond precision.
        // That output must stay diagnostic even if it looks close to the bracket.
        var dateRoot = root(); dateRoot["timestamp"] = launchWall.addingTimeInterval(1.125)
        let coarse = try PowermetricsPlistParser.parse(data(dateRoot), measurementContext: context(end: 1.9))
        assertBracket(coarse)
    }

    func testAmbiguousOutsideAndTooLongIntervalsNeverUseReapMinusDuration() throws {
        assertBracket(try parse(root(offset: 1.5), context(end: 3)))
        for offset in [-1.1, -0.1, 1.9, 4.1] { assertBracket(try parse(root(offset: offset))) }
        assertBracket(try parse(root(), context(end: 0.5)))
        assertBracket(try parse(root(), context(end: 5.1)))
    }

    func testClockStepsUnboundedAnchorsRegressionAndOverflowAreRejected() throws {
        for step in [-5.0, -0.002, 0.002, 5] { assertBracket(try parse(root(), context(wallStep: step))) }
        let invalid = [
            PowermetricsMeasurementContext(launched: anchor(launchNs, launchWall),
                finished: anchor(launchNs - 1, launchWall), helperBootID: boot),
            PowermetricsMeasurementContext(launched: .init(beforeMonotonicNs: launchNs,
                wallTime: launchWall, afterMonotonicNs: launchNs + 1_000_001),
                finished: anchor(101_200_000_000, launchWall.addingTimeInterval(1.2)), helperBootID: boot),
            PowermetricsMeasurementContext(launched: anchor(UInt64.max - 100, launchWall),
                finished: anchor(UInt64.max, launchWall.addingTimeInterval(1.2)), helperBootID: boot),
        ]
        for evidence in invalid { assertBracket(try parse(root(), evidence)) }
    }

    func testSystemClockIsSharedBySimulatedHelperAppAndWorkload() throws {
        let before = PowermetricsMonotonicClock.nanoseconds
        let helper = PowermetricsMeasurementContext.Anchor.capture()
        let workload = MSeriesV11Clock.nanoseconds
        let after = PowermetricsMonotonicClock.nanoseconds
        XCTAssertLessThanOrEqual(before, helper.beforeMonotonicNs)
        XCTAssertLessThanOrEqual(helper.beforeMonotonicNs, helper.afterMonotonicNs)
        XCTAssertLessThanOrEqual(helper.afterMonotonicNs, workload)
        XCTAssertLessThanOrEqual(workload, after)
        XCTAssertEqual(PowermetricsMonotonicClock.clockDomain, MSeriesV11Windows.clockDomain)
        let shared = try MiniWindowLogicFixtures.source("Sources/FanControlShared/PowermetricsSampling.swift")
        XCTAssertTrue(shared.contains("let ticks = mach_continuous_time()"))
    }

    func testPrivilegedRunnerConnectsLocalCaptureToOnlySuccessfulParseWithoutChangingRequest() throws {
        let runner = try MiniWindowLogicFixtures.source("Sources/FanControlHelper/PowermetricsProcessRunner.swift")
        XCTAssertTrue(runner.contains("launchClock = .capture()"))
        XCTAssertTrue(runner.contains("if waitStatus != nil && finishClock == nil { finishClock = .capture() }"))
        XCTAssertTrue(runner.contains("guard let launchClock, let finishClock else { return nil }"))
        XCTAssertTrue(runner.contains("PowermetricsMeasurementContext(launched: launchClock, finished: finishClock,"))
        XCTAssertTrue(runner.contains("if sample.timing != nil { return result }"), "native proof must not be overwritten by bracket-only fallback")
        let shared = try MiniWindowLogicFixtures.source("Sources/FanControlShared/PowermetricsSampling.swift")
        XCTAssertTrue(shared.contains("PowermetricsPlistParser.parse(output, measurementContext: measurementContext())"))
    }

    func testExecutionContextIsUsedOnlyOnSuccessfulBoundedEOF() throws {
        let bytes = try data(root())
        var contextCalls = 0
        let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { 1.2 }, read: {
            .init(stdout: bytes, stderr: Data(), reachedEOF: true, exitStatus: 0)
        }, kill: { XCTFail("valid command should be reaped") }, pause: {}, measurementContext: {
            contextCalls += 1; return self.context()
        })
        guard case .sample(let sample) = result else { return XCTFail("missing sample") }
        XCTAssertEqual(sample.timing?.timestampQuality, .helperMeasured)
        XCTAssertEqual(contextCalls, 1)
        for (time, huge, expected) in [(5.0, false, PowermetricsFailure.timedOut), (0, true, .outputTooLarge)] {
            var kills = 0
            let failure = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { time }, read: {
                .init(stdout: huge ? Data(repeating: 0, count: PowermetricsPlistParser.maximumOutputBytes + 1) : bytes,
                      stderr: Data(), reachedEOF: true, exitStatus: 0)
            }, kill: { kills += 1 }, pause: {}, measurementContext: {
                XCTFail("timeout/oversize must never build a measured envelope"); return self.context()
            })
            XCTAssertEqual(failure, .failure(expected)); XCTAssertEqual(kills, 1)
        }
    }

    func testNewAndLegacyXPCRepliesAreBidirectionallyDecodableAtVersionFour() throws {
        let sample = try parse(root())
        let reply = FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "ok",
            appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample))
        let encoded = try JSONEncoder().encode(reply)
        let new = try JSONDecoder().decode(FanControlHelperReply.self, from: encoded).validated(for: .samplePowerMetrics)
        XCTAssertEqual(new.powerSampleResult, .sample(sample))
        let legacy = try JSONDecoder().decode(LegacyReply.self, from: encoded)
        XCTAssertEqual(legacy.protocolVersion, 4)
        guard case .sample(let legacySample) = legacy.powerSampleResult else { return XCTFail("legacy decoder rejected new reply") }
        XCTAssertEqual(legacySample.cpuMilliwatts, 2_000)
        let oldBytes = try JSONEncoder().encode(legacy)
        let old = try JSONDecoder().decode(FanControlHelperReply.self, from: oldBytes).validated(for: .samplePowerMetrics)
        guard case .sample(let oldSample)? = old.powerSampleResult else { return XCTFail("new decoder rejected old reply") }
        XCTAssertNil(oldSample.timing)
        let converted = MSeriesV11TelemetryBridge.convert(.init(sample: oldSample,
            requestStartMonotonicNs: launchNs, responseReceivedMonotonicNs: 101_200_000_000,
            clockDomain: PowermetricsMonotonicClock.clockDomain))
        XCTAssertEqual(converted.telemetry.timestampQuality, "requestBracketOnly")
        XCTAssertNil(converted.telemetry.measurementStartMonotonicNs)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: FanControlHelperRequest.samplePowerMetrics.encodedForTransport()) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["protocolVersion", "operation"])
        for key in ["measurementContext", "timestamp", "helperBootID", "clockDomain", "launchClock"] {
            var forged = keys; forged[key] = "attacker"
            XCTAssertThrowsError(try PowermetricsSamplingRequest.decode(JSONSerialization.data(withJSONObject: forged)))
        }
    }

    func testParsedEnvelopeThroughBridgeCalculatesEfficiencyWithTwoDistinctCoverages() throws {
        let measured = try telemetry(measured: true)
        let batches = [MSeriesV11WindowTests.batch(100_000_000_000, 110_000_000_000, work: 1_000)]
        let resultPoint = point(batches, measured)
        XCTAssertEqual(resultPoint.validSampleCount, 5); XCTAssertEqual(resultPoint.expectedSampleCount, 5)
        XCTAssertEqual(resultPoint.sampleCoverageFraction, 1)
        XCTAssertEqual(resultPoint.timeCoverageFraction, 0.5)
        XCTAssertEqual(resultPoint.alignmentQuality, "measuredIntersections")
        for sample in try XCTUnwrap(resultPoint.efficiency).samples { XCTAssertEqual(sample.value, 50, accuracy: 1e-9) }
        XCTAssertEqual(resultPoint.joules, 10); XCTAssertEqual(resultPoint.matchedWorkUnits, 500)
        let diagnostic = point(batches, try telemetry(measured: false))
        XCTAssertNil(diagnostic.efficiency); XCTAssertNotNil(diagnostic.throughput)
        XCTAssertEqual(diagnostic.timestampQuality, "requestBracketOnly")
        XCTAssertEqual(diagnostic.alignmentQuality, "unavailable")
        XCTAssertEqual(diagnostic.sampleCoverageFraction, 0); XCTAssertEqual(diagnostic.timeCoverageFraction, 0)
        let fourMeasuredOneMissing = point(batches, Array(measured.dropFirst()) + [try telemetry(measured: false)[0]])
        XCTAssertEqual(fourMeasuredOneMissing.sampleCoverageFraction, 0.8)
        XCTAssertEqual(fourMeasuredOneMissing.timeCoverageFraction, 0.4)
        XCTAssertNotNil(fourMeasuredOneMissing.efficiency, "4/5 valid independent samples suffice when all three windows intersect")
        let unrelatedDiagnostic = try telemetry(measured: false)[0]
        let later = point([MSeriesV11WindowTests.batch(102_000_000_000, 112_000_000_000, work: 1_000)],
                          Array(measured.dropFirst()) + [unrelatedDiagnostic])
        XCTAssertNotNil(later.efficiency, "a previous stage's diagnostic sample must not poison this stage")
        let bytes = try JSONEncoder().encode(resultPoint)
        XCTAssertEqual(try JSONDecoder().decode(MSeriesV11EfficiencyPoint.self, from: bytes), resultPoint)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        oldObject.removeValue(forKey: "sampleCoverageFraction"); oldObject.removeValue(forKey: "timeCoverageFraction")
        let old = try JSONDecoder().decode(MSeriesV11EfficiencyPoint.self, from: JSONSerialization.data(withJSONObject: oldObject))
        XCTAssertNil(old.sampleCoverageFraction); XCTAssertNil(old.timeCoverageFraction)
    }

    private func telemetry(measured: Bool) throws -> [MSeriesV11Telemetry] {
        try (0..<5).map { i in
            let delta = Double(i * 2)
            let request = launchNs + UInt64(i * 2) * 1_000_000_000
            let evidence = PowermetricsMeasurementContext(launched: anchor(request, launchWall.addingTimeInterval(delta)),
                finished: anchor(request + 1_200_000_000, launchWall.addingTimeInterval(delta + 1.2)), helperBootID: boot)
            var value = root(offset: delta + 1.125)
            if !measured { value.removeValue(forKey: "timestamp") }
            let sample = try parse(value, evidence)
            return MSeriesV11TelemetryBridge.convert(.init(sample: sample, requestStartMonotonicNs: request,
                responseReceivedMonotonicNs: request + 1_200_000_000,
                clockDomain: PowermetricsMonotonicClock.clockDomain)).telemetry
        }
    }

    private func point(_ batches: [MSeriesV11Batch], _ telemetry: [MSeriesV11Telemetry]) -> MSeriesV11EfficiencyPoint {
        let start = batches[0].startMonotonicNs, end = start + 10_000_000_000
        let windows = MSeriesV11Windows.windows(id: MSeriesV11WindowTests.id, start: start, durationSeconds: 10,
            count: 3, finishedAt: end, batches: batches, telemetry: telemetry, gpu: false)
        return MSeriesV11Windows.efficiencyPoint(id: MSeriesV11WindowTests.id, workers: 8, coreType: "allLogical",
            windows: windows, batches: batches, telemetry: telemetry, extensionHash: MSeriesV11Protocol.contractHash)
    }

    private func assertBracket(_ sample: PowermetricsSample, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sample.timing?.timestampQuality, .requestBracketOnly, file: file, line: line)
        XCTAssertNil(sample.timing?.measurementStartMonotonicNs, file: file, line: line)
        XCTAssertNil(sample.timing?.measurementEndMonotonicNs, file: file, line: line)
        XCTAssertNil(sample.timing?.timestampSource, file: file, line: line)
    }

    // A literal pre-interval v4 DTO. Synthesized Codable ignores the new timing
    // member and reproduces the old enum wire shape in both directions.
    private struct LegacySample: Codable {
        let cpuMilliwatts: Double?
        let gpuMilliwatts: Double?
        let aneMilliwatts: Double?
        let clusters: [PowermetricsSample.ClusterFrequency]
        let gpuMegahertz: Double?
        let durationSeconds: Double
    }
    private enum LegacyResult: Codable { case sample(LegacySample), failure(PowermetricsFailure) }
    private struct LegacyReply: Codable {
        let protocolVersion: Int
        let operation: String
        let success: Bool
        let message: String
        let appliedTargetRPMByFan: [Int: Int]
        let powerSampleResult: LegacyResult
    }
}
