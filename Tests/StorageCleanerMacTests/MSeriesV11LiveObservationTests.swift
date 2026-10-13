import Foundation
import XCTest
@testable import StorageCleanerMac

/// All work and helper intervals below are inert numeric fixtures.
final class MSeriesV11LiveObservationTests: XCTestCase {
    func testLiveObservationUsesOnlyMatchingStageMeasuredIntersections() throws {
        let id = MSeriesV11WindowTests.id
        let batches = [MSeriesV11WindowTests.batch(0, 10_000_000_000, work: 1_000),
            MSeriesV11WindowTests.batch(0, 10_000_000_000, work: 99_000, id: "sustained.gpu")]
        let telemetry = (0..<5).map { MSeriesV11WindowTests.telemetry($0) }
        let sessionID = UUID()
        let live = MSeriesV11LiveObservation.make(sessionID: sessionID, stageID: id,
            batches: batches, telemetry: telemetry, end: 10_000_000_000, gpu: false)
        XCTAssertEqual(live.sessionID, sessionID)
        XCTAssertEqual(live.stageID, id)
        XCTAssertEqual(live.efficiency, 50)
        XCTAssertEqual(live.observedSeconds, 5)
        XCTAssertEqual(live.unit, "fixed-fixtures/J")
    }
    func testRequestBracketsMissingPowerAndAnotherStageNeverBecomeZeroEfficiency() {
        let batches = [MSeriesV11WindowTests.batch(0, 10_000_000_000)]
        for telemetry in [[], (0..<5).map { MSeriesV11WindowTests.telemetry($0, quality: "requestBracketOnly") },
                          (0..<5).map { MSeriesV11WindowTests.telemetry($0, mw: 0) }] {
            let live = MSeriesV11LiveObservation.make(sessionID: UUID(), stageID: MSeriesV11WindowTests.id,
                batches: batches, telemetry: telemetry, end: 10_000_000_000, gpu: false)
            XCTAssertNil(live.efficiency)
            XCTAssertEqual(live.observedSeconds, 0)
        }
        let other = MSeriesV11LiveObservation.make(sessionID: UUID(), stageID: "sustained.cpu.allCores",
            batches: batches, telemetry: (0..<5).map { MSeriesV11WindowTests.telemetry($0) },
            end: 10_000_000_000, gpu: false)
        XCTAssertNil(other.efficiency)
    }
    func testGPUObservationUsesReportedGPUPowerAndWallWork() throws {
        let id = "power.gpu.peak"
        let batch = MSeriesV11WindowTests.batch(0, 10_000_000_000, work: 1_000, id: id, gpu: 1)
        let live = MSeriesV11LiveObservation.make(sessionID: UUID(), stageID: id, batches: [batch],
            telemetry: (0..<5).map { MSeriesV11WindowTests.telemetry($0) }, end: 10_000_000_000, gpu: true)
        XCTAssertEqual(live.efficiency, 25, "100 wall work/s divided by 4 W; GPU activity throughput is not used")
        XCTAssertEqual(live.unit, "Mtri/J")
    }
    func testIrregularPowerCoordinatesDriveHoverDragAndPointGeometry() throws {
        let powers = [0.05, 0.1, 0.9]
        let samples = powers.enumerated().map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element) }
        XCTAssertEqual(LightfieldChartGeometry.index(at: 11, width: 100, count: 3, xFractions: powers), 1)
        XCTAssertEqual(LightfieldChartGeometry.index(at: 80, width: 100, count: 3, xFractions: powers), 2)
        XCTAssertEqual(try XCTUnwrap(LightfieldChartGeometry.dragSelection(startX: 5, currentX: 11, width: 100,
            samples: samples, xFractions: powers)).range, 0...1)
        XCTAssertEqual(LightfieldChartGeometry.point(xFraction: 0.1, value: 0.75,
            size: CGSize(width: 100, height: 40)), CGPoint(x: 10, y: 10))
        XCTAssertNil(LightfieldChartGeometry.index(at: .nan, width: 100, count: 3, xFractions: powers))
    }
#if DEBUG
    func testPageRejectsTamperedRawPowerEvidenceForAllFourEfficiencyPoints() throws {
        var envelope = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11)
        XCTAssertEqual(envelope.efficiencyPoints.filter { MSeriesV11PagePresentation.measuredEfficiencyPoint($0, in: envelope) }.count, 4)
        envelope.telemetry = []
        XCTAssertFalse(MSeriesV11PagePresentation.hasMeasuredEfficiency(envelope))
        XCTAssertTrue(envelope.efficiencyPoints.allSatisfy { !MSeriesV11PagePresentation.measuredEfficiencyPoint($0, in: envelope) })
    }
    func testResultKeepsAtLeast96PointsForScrollableDetailsAcrossSevenWindowSizes() {
        for window in [CGSize(width: 820, height: 560), .init(width: 1000, height: 700), .init(width: 1280, height: 763),
                       .init(width: 1680, height: 1050), .init(width: 2400, height: 1350), .init(width: 677, height: 390), .init(width: 1280, height: 390)] {
            let canvas = CGSize(width: window.width - 210, height: window.height - 28)
            let geometry = FeatureLightfieldGeometry(size: canvas, phase: .result)
            let layout = MSeriesV11PagePresentation.ResultLayout(width: geometry.content.width, height: geometry.content.height)
            if layout.pinsSummary { XCTAssertGreaterThanOrEqual(geometry.content.height - layout.summaryHeight - 24, 96) }
            if window.height <= 560 { XCTAssertFalse(layout.pinsSummary, "Compact canvases put the summary inside the scroll view") }
        }
    }
    func testSavingAndCancellingKeepCoreSubprogressAndPressureRemainsIndependent() {
        let saving = MSeriesV11PagePresentation.Run(state: .phase(.persisting, sessionID: UUID()), weightedFraction: 1,
            elapsedSeconds: 452, knownCoreCount: 18)
        XCTAssertEqual(saving.completedCoreCount, 18)
        XCTAssertEqual(saving.displayedFraction, 0.99)
        let cancelled = MSeriesV11PagePresentation.Run(state: .phase(.cancelling, sessionID: UUID()), weightedFraction: 0.3,
            elapsedSeconds: 40, knownCoreCount: 7)
        XCTAssertEqual(cancelled.completedCoreCount, 7)
        let pressure = MSeriesV11PagePresentation.Run(state: .phase(.persisting, sessionID: UUID()), weightedFraction: 1,
            elapsedSeconds: 620, mode: "pressure10m")
        XCTAssertEqual(pressure.completedCoreCount, 0)
    }
#endif
}
