import Foundation
import XCTest
@testable import StorageCleanerMac

#if DEBUG
final class MSeriesV11EvidencePresentationTests: XCTestCase {
    static func record(_ metric: MSeriesMeasurement, otherMetrics: [MSeriesMeasurement] = [], environment: MSeriesV11Environment = MSeriesV11TestFixtures.nominal) throws -> BenchmarkV7Result {
        let base = MSeriesV11PageFixture.result()
        let old = try XCTUnwrap(base.mSeries)
        let core = MSeriesResult(sessionID: old.sessionID, schema: old.schema, plan: old.plan, workload: old.workload,
            fixture: old.fixture, implementation: old.implementation, statisticsVersion: old.statisticsVersion,
            scoringVersion: old.scoringVersion, referenceVersion: old.referenceVersion, contractHash: old.contractHash,
            hardware: old.hardware, coreEnvironment: old.coreEnvironment, metrics: [metric] + otherMetrics, extensions: [],
            cancelled: false, globalFailure: nil, writtenBytes: 0, startedAt: old.startedAt, completedAt: old.completedAt)
        var envelope = try XCTUnwrap(base.mSeriesV11)
        envelope.perStageEnvironment["core"] = [environment]
        return .init(recordID: base.recordID, mSeries: core, mSeriesV11: envelope, session: base.session,
            preflight: base.preflight, versions: base.versions, metrics: [], coreScore: nil,
            completedAt: base.completedAt, failure: nil)
    }
    private func metric(_ values: [Double] = [100, 100, 100], elapsed: Double = 1, checksum: UInt64 = 1) throws -> MSeriesMeasurement {
        .init(id: "memory.copy", unit: "GB/s", availability: .available, reason: nil,
            samples: values.map { .init(value: $0, elapsedSeconds: elapsed, wallElapsedSeconds: elapsed, checksum: checksum) },
            statistics: try BenchmarkStatistics.summarize(values), repetitions: 3, workers: 1)
    }
    func testEachRawComparisonRequiresEligibleEnvironmentCVAndTimingOnBothSides() throws {
        let clean = try metric()
        let current = try Self.record(clean), previous = try Self.record(clean)
        XCTAssertNotNil(MSeriesV11PagePresentation.comparison(clean, previous: clean, currentResult: current, previousResult: previous))
        var battery = MSeriesV11TestFixtures.nominal; battery.powerSource = "Battery Power"
        var fair = MSeriesV11TestFixtures.nominal; fair.thermalState = 1
        var lowPower = MSeriesV11TestFixtures.nominal; lowPower.lowPower = true
        var unknown = MSeriesV11TestFixtures.nominal; unknown.backgroundLoadHigh = nil
        for env in [battery, fair, lowPower, unknown] {
            let limited = try Self.record(clean, environment: env)
            XCTAssertEqual(MSeriesV11PagePresentation.metricEligibility(clean, in: limited).status, .restricted)
            XCTAssertNil(MSeriesV11PagePresentation.comparison(clean, previous: clean, currentResult: limited, previousResult: previous))
            XCTAssertNil(MSeriesV11PagePresentation.comparison(clean, previous: clean, currentResult: current, previousResult: limited))
        }
        for invalid in [try metric([80, 100, 120]), try metric(elapsed: 0), try metric(checksum: 0)] {
            let result = try Self.record(invalid)
            XCTAssertEqual(MSeriesV11PagePresentation.metricEligibility(invalid, in: result).status, .incomparable)
            XCTAssertNil(MSeriesV11PagePresentation.comparison(invalid, previous: clean, currentResult: result, previousResult: previous))
            XCTAssertNil(MSeriesV11PagePresentation.comparison(clean, previous: invalid, currentResult: current, previousResult: result))
        }
        XCTAssertNil(MSeriesV11PagePresentation.comparison(clean, previous: clean), "missing eligibility evidence is not comparable")
    }
    func testUnrelatedInvalidItemDoesNotSuppressEligibleRawComparison() throws {
        let clean = try metric()
        let bad = MSeriesMeasurement(id: "storage.seqRead", unit: "GB/s", availability: .available, reason: nil,
            samples: [.init(value: 100, elapsedSeconds: 0, wallElapsedSeconds: 0, checksum: 1), .init(value: 100, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1), .init(value: 100, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1)],
            statistics: try BenchmarkStatistics.summarize([100, 100, 100]), repetitions: 3, workers: 1)
        let mixed = try Self.record(clean, otherMetrics: [bad]), previous = try Self.record(clean)
        XCTAssertFalse(try XCTUnwrap(mixed.mSeries).isValid)
        XCTAssertEqual(MSeriesV11PagePresentation.metricEligibility(clean, in: mixed).status, .comparable)
        XCTAssertEqual(MSeriesV11PagePresentation.metricEligibility(bad, in: mixed).status, .incomparable)
        XCTAssertNotNil(MSeriesV11PagePresentation.comparison(clean, previous: clean, currentResult: mixed, previousResult: previous))
    }

    func testRestrictedScoresKeepNumbersButExposeEveryReasonAndGrayStatus() throws {
        var environment = MSeriesV11TestFixtures.nominal
        environment.powerSource = "Battery Power"; environment.lowPower = true
        let metrics = MSeriesScoringV11.inputIDs.map { MSeriesV11TestFixtures.metric($0, environment: [environment]) }
        let scores = MSeriesScoringV11.evaluate(metrics: metrics,
            reference: try MSeriesV11TestFixtures.load(MSeriesV11TestFixtures.reference()),
            extensionHash: MSeriesV11TestFixtures.extensionHash)
        var envelope = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11); envelope.scores = scores
        for id in ["chip", "system", "efficiency"] {
            XCTAssertGreaterThan(try XCTUnwrap(scores.componentScores[id]), 0)
            XCTAssertTrue(MSeriesV11PagePresentation.scoreRestricted(id, result: envelope))
            let reason = try XCTUnwrap(MSeriesV11PagePresentation.scoreReason(id, result: envelope))
            XCTAssertTrue(reason.contains(L10n.text("电池供电", "Battery power")))
            XCTAssertTrue(reason.contains(L10n.text("省电模式", "Low Power Mode")))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11ResultPage.swift"), encoding: .utf8)
        XCTAssertTrue(page.contains("primaryStatus: chip.status"))
        XCTAssertTrue(page.contains("ScoreDisplay(id: \"chip\", result: envelope).metric"))
        XCTAssertTrue(page.contains("[\"system\", \"efficiency\"].map { MSeriesV11PagePresentation.ScoreDisplay(id: $0, result: envelope).metric }"))
        XCTAssertTrue(page.contains("if let reason = display.reason"))
        for id in ["chip", "system", "efficiency"] {
            let display = MSeriesV11PagePresentation.ScoreDisplay(id: id, result: envelope)
            XCTAssertEqual(display.metric.status, .unknown)
            XCTAssertEqual(display.reason, MSeriesV11PagePresentation.scoreReason(id, result: envelope))
        }
        let components = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift"), encoding: .utf8)
        XCTAssertTrue(components.contains("primaryStatus?.color(palette) ?? palette.fg"))
        XCTAssertTrue(components.contains("metric.status?.color(palette) ?? palette.fg"))
    }
    func testPersistingAloneCannotProveCompletedCoreAndPendingEvidenceCorrectsCount() throws {
        let session = UUID()
        var configuration = MSeriesV11RunConfiguration(sessionID: session, mode: "standard", accelerators: [])
        XCTAssertEqual(MSeriesV11PagePresentation.Run(state: .phase(.persisting, sessionID: session), weightedFraction: 1,
            elapsedSeconds: 50).completedCoreCount, 0)
        configuration.accept(.phase(.running, sessionID: session, workloadID: MSeriesProtocol.coreIDs[7]))
        XCTAssertEqual(configuration.completedCoreCount, 7)
        configuration.accept(.phase(.persisting, sessionID: session))
        XCTAssertEqual(configuration.completedCoreCount, 7)
        configuration.accept(.phase(.running, sessionID: UUID(), workloadID: "power.gpu.peak"))
        XCTAssertEqual(configuration.completedCoreCount, 7, "another session cannot update the frozen count")
    }
}
#endif
