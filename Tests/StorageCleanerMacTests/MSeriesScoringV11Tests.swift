import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesScoringV11Tests: XCTestCase {
    private func score(_ metrics: [MSeriesV11Metric] = MSeriesV11TestFixtures.metrics,
                       final: Bool = false, mode: String = "standard") throws -> MSeriesV11Scores {
        let reference = try MSeriesV11TestFixtures.load(MSeriesV11TestFixtures.reference(final: final))
        XCTAssertNotNil(reference.reference)
        return MSeriesScoringV11.evaluate(metrics: metrics, reference: reference,
            extensionHash: MSeriesV11TestFixtures.extensionHash, mode: mode)
    }
    func testExactFrozenContractsAndEveryRatioOneProduces1000() throws {
        XCTAssertEqual(MSeriesProtocol.contractHash, "c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318")
        XCTAssertEqual(MSeriesV11Digest.sha256(Data(MSeriesScoringV11.contract.utf8)), MSeriesScoringV11.scoringContractHash)
        let result = try score()
        XCTAssertEqual(result.componentScores.count, 32)
        for value in result.componentScores.values { XCTAssertEqual(value, 1000, accuracy: 1e-8) }
        XCTAssertTrue(result.labels.values.allSatisfy { $0.status == .comparable })
        XCTAssertEqual(result.displayScore("chip"), "暂定 1000")
        XCTAssertEqual(try score(final: true).displayScore("chip"), "1000")
    }
    func testWeightsAndInversePointerChaseUseRatiosOnce() throws {
        var values = MSeriesV11TestFixtures.metrics.map { metric in
            metric.id.hasPrefix("cpu.single.") ? MSeriesV11TestFixtures.metric(metric.id, values: [200,200,200]) : metric
        }
        values = values.map { $0.id == "memory.pointerChase" ? MSeriesV11TestFixtures.metric($0.id, values: [50,50,50]) : $0 }
        let result = try score(values)
        XCTAssertEqual(try XCTUnwrap(result.componentScores["cpu"]), 1000 * pow(2,0.3), accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(result.componentScores["chip"]), 1000 * pow(2,0.3 * 0.7), accuracy: 1e-7)
        XCTAssertEqual(result.componentScores["memory.pointerChase"], 2000)
        XCTAssertEqual(try XCTUnwrap(result.componentScores["memory"]), 1000 * pow(2,1.0/3), accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(result.systemScore), 1000 * pow(2,0.3 * 0.7 * 0.55 + 0.20 / 3), accuracy: 1e-7)
        var gpu = MSeriesV11TestFixtures.metrics.filter { $0.id != MSeriesScoringV11.peakID && $0.id != MSeriesScoringV11.sustainedID }
        gpu += [MSeriesV11TestFixtures.metric(MSeriesScoringV11.peakID, values: [400,400,400]),
                MSeriesV11TestFixtures.metric(MSeriesScoringV11.sustainedID, values: Array(repeating: 200, count: 6))]
        let gpuResult = try score(gpu)
        XCTAssertEqual(try XCTUnwrap(gpuResult.componentScores["gpuPeak"]), 1000 * pow(4,0.25), accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(gpuResult.componentScores["gpu"]), 1000 * pow(4,0.25 * 0.5) * pow(2,0.5), accuracy: 1e-7)
    }
    func testBoundsInclusiveAndRejectOutliersWithoutReweighting() throws {
        for value in [2.0, 500.0] {
            let result = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != "cpu.single.integer" }
                + [MSeriesV11TestFixtures.metric("cpu.single.integer", values: [value,value,value])])
            XCTAssertNotNil(result.componentScores["cpuSingle"])
        }
        for value in [1.999, 500.001, 0, -1, .nan, .infinity] {
            let result = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != "cpu.single.integer" }
                + [MSeriesV11TestFixtures.metric("cpu.single.integer", values: [value,value,value])])
            XCTAssertNil(result.componentScores["cpuSingle"])
            XCTAssertNil(result.chipScore)
            XCTAssertNil(result.systemScore)
            XCTAssertNotNil(result.componentScores["cpuMulti"])
            XCTAssertNotNil(result.componentScores["gpu"])
        }
        let missing = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != MSeriesScoringV11.sustainedID })
        XCTAssertNil(missing.componentScores["gpu"])
        XCTAssertNotNil(missing.componentScores["gpuPeak"])
        XCTAssertNotNil(missing.componentScores["cpu"])
        XCTAssertEqual(missing.labels["system"]?.status, .incomparable)
    }
    func testCVGateIsIndependentOfMADAndMissingChecksumInvalidatesOnlyDependents() throws {
        let spiky = MSeriesV11TestFixtures.metric("cpu.single.integer", values: [100,100,130])
        XCTAssertEqual(spiky.statistics?.confidence, .a)
        XCTAssertGreaterThan(try XCTUnwrap(spiky.sampleCV), 0.05)
        let invalid = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != spiky.id } + [spiky])
        XCTAssertNil(invalid.componentScores["cpuSingle"])
        XCTAssertTrue(invalid.labels[spiky.id]!.reasonCodes.contains("unstableSamples"))
        let noChecksum = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != "memory.copy" }
            + [MSeriesV11TestFixtures.metric("memory.copy", checksum: nil)])
        XCTAssertNil(noChecksum.componentScores["memory"])
        XCTAssertNotNil(noChecksum.chipScore)
        let duplicate = try score(MSeriesV11TestFixtures.metrics + [MSeriesV11TestFixtures.metric("memory.copy")])
        XCTAssertNil(duplicate.componentScores["memory"])
    }
    func testScopedEnvironmentPrecedenceAndPressureRawOnly() throws {
        var fair = MSeriesV11TestFixtures.nominal; fair.thermalState = 1; fair.lowPower = true; fair.powerChanged = true
        let restricted = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != MSeriesScoringV11.efficiencyID }
            + [MSeriesV11TestFixtures.metric(MSeriesScoringV11.efficiencyID, environment: [fair])])
        XCTAssertNotNil(restricted.efficiencyScore)
        XCTAssertEqual(restricted.labels["efficiency"]?.status, .restricted)
        XCTAssertEqual(restricted.labels["chip"]?.status, .comparable)
        XCTAssertEqual(restricted.labels["system"]?.status, .comparable)
        var debug = fair; debug.releaseBuild = false; debug.translated = true
        let label = MSeriesScoringV11.environmentLabel([debug])
        XCTAssertEqual(label.status, .incomparable)
        XCTAssertTrue(Set(label.reasonCodes).isSuperset(of: ["debugBuild","rosetta","thermalFair","lowPower","powerChanged"]))
        XCTAssertEqual(MSeriesScoringV11.environmentLabel([]).status, .restricted)
        XCTAssertTrue(try score(mode: "pressure10m").componentScores.isEmpty)
    }
    func testUnavailableReferenceAndUnreliableGPUTimelineProduceNoInventedScore() throws {
        let result = MSeriesScoringV11.evaluate(metrics: MSeriesV11TestFixtures.metrics, reference: .unavailable,
            extensionHash: MSeriesV11TestFixtures.extensionHash)
        XCTAssertTrue(result.componentScores.isEmpty)
        XCTAssertEqual(result.referenceIdentity.referenceStatus, .unavailable)
        XCTAssertEqual(result.displayScore("cpu"), "待校准")
        let fallback = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != MSeriesScoringV11.peakID }
            + [MSeriesV11TestFixtures.metric(MSeriesScoringV11.peakID, fallback: true)])
        XCTAssertNil(fallback.chipScore)
        XCTAssertNotNil(fallback.componentScores["cpu"])
        let missingEfficiency = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != MSeriesScoringV11.efficiencyID })
        XCTAssertNil(missingEfficiency.efficiencyScore)
        XCTAssertNotNil(missingEfficiency.systemScore)
    }

    func testInclusiveCVThresholdsAndMissingMeasuredPowerAlignment() throws {
        for (id, values) in [("cpu.single.integer", [95.0,100,105]), ("gpu.compute.fp32", [90.0,100,110]),
                             ("storage.seqWrite", [90.0,100,110])] {
            let result = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != id }
                + [MSeriesV11TestFixtures.metric(id, values: values)])
            XCTAssertNotNil(result.componentScores[id], id)
        }
        var efficiency = MSeriesV11TestFixtures.metric(MSeriesScoringV11.efficiencyID)
        efficiency.powerAlignment = nil
        let result = try score(MSeriesV11TestFixtures.metrics.filter { $0.id != efficiency.id } + [efficiency])
        XCTAssertNil(result.efficiencyScore)
        XCTAssertNotNil(result.systemScore)
        XCTAssertTrue(result.labels["efficiency"]!.reasonCodes.contains("powerAlignmentUnavailable"))
        efficiency.powerAlignment = .init(timestampQuality: "requestBracketOnly", expectedSampleCount: 5,
            validSampleCount: 5, windows: Array(repeating: .init(matchedWorkUnits: 100, joules: 1, observedSeconds: 1, validSampleCount: 2), count: 3))
        XCTAssertNil(try score(MSeriesV11TestFixtures.metrics.filter { $0.id != efficiency.id } + [efficiency]).efficiencyScore)
    }
}
