import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11WindowTests: XCTestCase {
    static let id = "power.cpu.allCores"
    static func batch(_ start: UInt64, _ end: UInt64, work: Double = 100, id: String = id, gpu: Double? = nil) -> MSeriesV11Batch {
        .init(stageID: id, startMonotonicNs: start, endMonotonicNs: end, workUnits: work, gpuElapsedSeconds: gpu,
            checksum: 1, clockDomain: MSeriesV11Windows.clockDomain)
    }
    static func telemetry(_ index: Int, start: UInt64? = nil, end: UInt64? = nil, quality: String = "helperMeasured",
                          domain: String = MSeriesV11Windows.clockDomain, mw: Double? = 2000) -> MSeriesV11Telemetry {
        let a = start ?? UInt64(index * 2) * 1_000_000_000
        let b = end ?? a + 1_000_000_000
        return .init(sampleID: "s\(index)", helperBootID: "test-helper", clockDomain: domain,
            measurementStartMonotonicNs: a, measurementEndMonotonicNs: b, requestStartMonotonicNs: min(a, b),
            responseReceivedMonotonicNs: max(a, b), durationSeconds: b > a ? Double(b - a) / 1e9 : 1,
            cpuMilliwatts: mw, gpuMilliwatts: 4000, aneMilliwatts: nil, timestampQuality: quality)
    }
    static func point(batches: [MSeriesV11Batch], telemetry: [MSeriesV11Telemetry]) -> MSeriesV11EfficiencyPoint {
        let windows = MSeriesV11Windows.windows(id: id, start: 0, durationSeconds: 10, count: 3, finishedAt: 10_000_000_000,
            batches: batches, telemetry: telemetry, gpu: false)
        return MSeriesV11Windows.efficiencyPoint(id: id, workers: 8, coreType: "allLogical", windows: windows, batches: batches,
            telemetry: telemetry, extensionHash: MSeriesV11Protocol.contractHash)
    }
    func testCrossWindowWorkIsApportionedAndGapsStayInWallDenominator() throws {
        let batches = [Self.batch(0, 6_000_000_000, work: 600), Self.batch(8_000_000_000, 10_000_000_000, work: 200)]
        let windows = MSeriesV11Windows.windows(id: Self.id, start: 0, durationSeconds: 10, count: 2,
            finishedAt: 10_000_000_000, batches: batches, telemetry: [], gpu: false)
        XCTAssertEqual(windows[0].workUnits, 500, accuracy: 1e-9)
        XCTAssertEqual(windows[1].workUnits, 300, accuracy: 1e-9)
        XCTAssertEqual(windows[1].wallThroughput, 60)
        XCTAssertNil(windows[0].powerW); XCTAssertNil(windows[0].temperatureC)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.workUnits }, 800)
    }
    func testPowerUsesMeasuredIntersectionsIndependentIDsAndNeverFillsGaps() throws {
        let batches = [Self.batch(0, 10_000_000_000, work: 1000)]
        let telemetry = (0..<5).map { Self.telemetry($0) }
        let power = MSeriesV11Windows.power(start: 0, end: 10_000_000_000, batches: batches, telemetry: telemetry, gpu: false)
        XCTAssertEqual(power.joules, 10)
        XCTAssertEqual(power.observedSeconds, 5)
        XCTAssertEqual(power.matchedWork, 500)
        XCTAssertEqual(power.efficiency, 50)
        XCTAssertEqual(power.watts, 2)
        let point = Self.point(batches: batches, telemetry: telemetry)
        XCTAssertEqual(point.validSampleCount, 5)
        for sample in try XCTUnwrap(point.efficiency).samples { XCTAssertEqual(sample.value, 50, accuracy: 1e-12) }
        XCTAssertEqual(point.observedSeconds, 5)
        XCTAssertNotNil(point.throughput)
        let four = Self.point(batches: batches, telemetry: Array(telemetry.dropFirst()))
        XCTAssertNotNil(four.efficiency)
        let three = Self.point(batches: batches, telemetry: Array(telemetry.suffix(3)))
        XCTAssertNil(three.efficiency)
        XCTAssertNotNil(three.throughput)
        let threeAcrossEveryWindow = Self.point(batches: batches, telemetry: [telemetry[0], telemetry[2], telemetry[4]])
        XCTAssertEqual(threeAcrossEveryWindow.validSampleCount, 3)
        XCTAssertNil(threeAcrossEveryWindow.efficiency, "every window has a sample, but 3/5 independent coverage still fails")
        let duplicate = Self.point(batches: batches, telemetry: telemetry + [telemetry[0],telemetry[1]])
        XCTAssertNil(duplicate.efficiency)
    }
    func testMissingUntimedWrongDomainInvertedAndZeroPowerCannotFabricateEfficiency() {
        let batches = [Self.batch(0, 10_000_000_000)]
        // Only timestamp quality differs: the same IDs, clock, measured-shaped
        // intervals, positive power and complete workload pass as helperMeasured.
        let measured = (0..<5).map { Self.telemetry($0) }
        XCTAssertNotNil(Self.point(batches: batches, telemetry: measured).efficiency)
        let bracketOnly = (0..<5).map { Self.telemetry($0, quality: "requestBracketOnly") }
        let diagnostic = MSeriesV11Windows.power(start: 0, end: 10_000_000_000,
            batches: batches, telemetry: bracketOnly, gpu: false)
        XCTAssertEqual(diagnostic.observedSeconds, 0)
        XCTAssertEqual(diagnostic.joules, 0)
        XCTAssertEqual(diagnostic.matchedWork, 0)
        XCTAssertTrue(diagnostic.sampleIDs.isEmpty)
        let unavailable = Self.point(batches: batches, telemetry: bracketOnly)
        XCTAssertNil(unavailable.efficiency)
        XCTAssertEqual(unavailable.alignmentQuality, "unavailable")
        XCTAssertEqual(unavailable.validSampleCount, 0)
        XCTAssertTrue(unavailable.missingReasons.contains("timestampMissing"))
        XCTAssertTrue(unavailable.missingReasons.contains("insufficientPowerSampleCoverage"))
        XCTAssertNotNil(unavailable.throughput)
        for telemetry in [[], (0..<5).map { Self.telemetry($0, quality: "requestBracketOnly") },
                          (0..<5).map { Self.telemetry($0, domain: "wall-clock") },
                          (0..<5).map { Self.telemetry($0, start: 9, end: 1) },
                          (0..<5).map { Self.telemetry($0, mw: 0) }] {
            let point = Self.point(batches: batches, telemetry: telemetry)
            XCTAssertNil(point.efficiency)
            XCTAssertNotNil(point.throughput)
            XCTAssertFalse(point.missingReasons.isEmpty)
        }
    }
    func testGPUUsesActivityForScoreAndMatchingWallWorkForEfficiency() throws {
        let id = "power.gpu.peak"
        let batches = [Self.batch(0, 30_000_000_000, work: 300, id: id, gpu: 3)]
        let telemetry = (0..<15).map { Self.telemetry($0) }
        let windows = MSeriesV11Windows.windows(id: id, start: 0, durationSeconds: 30, count: 3,
            finishedAt: 30_000_000_000, batches: batches, telemetry: telemetry, gpu: true)
        XCTAssertEqual(windows.map(\.wallThroughput), [10,10,10])
        XCTAssertEqual(windows.map(\.gpuTimedThroughput), [100,100,100])
        let point = MSeriesV11Windows.efficiencyPoint(id: id, workers: 1, coreType: "gpu", windows: windows,
            batches: batches, telemetry: telemetry, extensionHash: MSeriesV11Protocol.contractHash)
        XCTAssertEqual(point.efficiency?.samples.map(\.value), [2.5,2.5,2.5])
        XCTAssertEqual(point.throughput?.samples.map(\.value), [100,100,100])
        XCTAssertEqual(point.efficiency?.contract.unit, "Mtri/J")
        XCTAssertEqual(point.efficiency?.contract.timing, "aligned-measured-wall")
        XCTAssertNil(MSeriesV11Windows.windows(id: id, start: 0, durationSeconds: 30, count: 3,
            finishedAt: 30_000_000_000, batches: [Self.batch(0, 30_000_000_000, id: id)], telemetry: [], gpu: true)[0].gpuTimedThroughput)
    }
    func testSustainedTailKeepsDecayAndRetentionAboveOneAndRejectsPartial() throws {
        for duration in [90,300] {
            let id = "sustained.cpu.allCores"
            let batches = (0..<duration/5).map { i in Self.batch(UInt64(i * 5) * 1_000_000_000,
                UInt64((i + 1) * 5) * 1_000_000_000, work: i < 2 ? 500 : 600, id: id) }
            let windows = MSeriesV11Windows.windows(id: id, start: 0, durationSeconds: duration, count: duration/5,
                finishedAt: UInt64(duration) * 1_000_000_000, batches: batches, telemetry: [], gpu: false)
            let result = MSeriesV11Windows.sustained(id: id, duration: duration, windows: windows,
                batches: batches, extensionHash: MSeriesV11Protocol.contractHash, gpu: false)
            XCTAssertEqual(result.first10Median, 100)
            XCTAssertEqual(result.tail30Metric?.statistics?.median, 120)
            XCTAssertEqual(result.retention, 1.2)
            XCTAssertEqual(result.tail30Metric?.samples.count, 6)
            XCTAssertTrue(windows.allSatisfy { $0.powerW == nil && $0.temperatureC == nil })
            let partial = MSeriesV11Windows.windows(id: id, start: 0, durationSeconds: duration, count: duration/5,
                finishedAt: 5_000_000_000, batches: [batches[0]], telemetry: [], gpu: false)
            XCTAssertNil(MSeriesV11Windows.sustained(id: id, duration: duration, windows: partial,
                batches: [batches[0]], extensionHash: MSeriesV11Protocol.contractHash, gpu: false).retention)
        }
    }
    func testLateObservationKeepsRawWorkAndMarksSuspendedWindows() {
        let observations = [0, 8].map { i in MSeriesV11Observation(atMonotonicNs: UInt64(i) * 1_000_000_000,
            cpuTemperatureC: nil, gpuTemperatureC: nil, environment: MSeriesV11TestFixtures.nominal) }
        let windows = MSeriesV11Windows.windows(id: Self.id, start: 0, durationSeconds: 10, count: 3,
            finishedAt: 10_000_000_000, batches: [Self.batch(0,10_000_000_000)], telemetry: [], observations: observations, gpu: false)
        XCTAssertTrue(windows[0].validityReasons.contains("environmentObservationLate"))
        XCTAssertGreaterThan(windows[0].workUnits, 0)
        XCTAssertNil(MSeriesV11Windows.efficiencyPoint(id: Self.id, workers: 8, coreType: "allLogical", windows: windows,
            batches: [Self.batch(0,10_000_000_000)], telemetry: [], extensionHash: MSeriesV11Protocol.contractHash).throughput)
    }

    func testP1ScoringRequiresRawTelemetryAndCoherentWorkIntervals() throws {
        let batches = [Self.batch(0, 10_000_000_000, work: 1000)]
        let telemetry = (0..<5).map { Self.telemetry($0) }
        let point = Self.point(batches: batches, telemetry: telemetry)
        var envelope = MSeriesV11Result(sessionID: UUID(), extensionContractHash: MSeriesV11Protocol.contractHash, rawPayloadSHA256: "")
        envelope.efficiencyPoints = [point]; envelope.workloadBatches = batches; envelope.telemetry = telemetry
        XCTAssertTrue(MSeriesV11Windows.validatesEfficiency(point, envelope: envelope))
        XCTAssertTrue(MSeriesScoringV11.inputs(core: MSeriesV11TestFixtures.legacyCore(), envelope: envelope).contains { $0.id == MSeriesScoringV11.efficiencyID })
        envelope.telemetry = []
        XCTAssertFalse(MSeriesV11Windows.validatesEfficiency(point, envelope: envelope))
        XCTAssertFalse(MSeriesScoringV11.inputs(core: MSeriesV11TestFixtures.legacyCore(), envelope: envelope).contains { $0.id == MSeriesScoringV11.efficiencyID })
        envelope.telemetry = telemetry
        envelope.workloadBatches = [Self.batch(10_000_000_000,0)]
        XCTAssertFalse(MSeriesV11Windows.validatesEfficiency(point, envelope: envelope))
    }
}
