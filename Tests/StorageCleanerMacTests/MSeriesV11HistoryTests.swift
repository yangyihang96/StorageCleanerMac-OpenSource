import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11HistoryTests: XCTestCase {
    func testLegacyCoreDecodeKeepsSchemaPlanHashesAndNilNewEnvelope() throws {
        let result = MSeriesV11TestFixtures.result()
        let bytes = try JSONEncoder().encode(result)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for key in ["mSeriesV11","runtimeWarnings","workloadExecutions","completionStatus","hardwareProfile"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.mSeriesV11)
        XCTAssertEqual(decoded.mSeries?.schema, MSeriesProtocol.schema)
        XCTAssertEqual(decoded.mSeries?.plan, MSeriesProtocol.plan)
        XCTAssertEqual(decoded.mSeries?.contractHash, result.mSeries?.contractHash)
        XCTAssertTrue(decoded.isPersistable)
        XCTAssertNil(decoded.mSeries?.overallIndex)
        XCTAssertEqual(decoded.runtimeWarnings, [])
        let v6 = MacBenchmarkResult.incomplete(completed: [.cpuSingle: 100])
        let v6Data = try JSONEncoder().encode(v6)
        XCTAssertEqual(try JSONDecoder().decode(MacBenchmarkResult.self, from: v6Data), v6)
    }
    func testMissingV11OptionalKeysAndUnknownAcceleratorAvailabilityRemainReadOnly() throws {
        let envelope = MSeriesV11Result(sessionID: UUID(), extensionContractHash: MSeriesV11TestFixtures.extensionHash,
            rawPayloadSHA256: String(repeating: "b", count: 64))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        for key in ["efficiencyPoints","accelerators","legacyExtensions","perStageEnvironment","telemetry","missingReasons"] { object.removeValue(forKey: key) }
        var decoded = try JSONDecoder().decode(MSeriesV11Result.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.efficiencyPoints, []); XCTAssertNil(decoded.scores); XCTAssertNil(decoded.state)
        XCTAssertEqual(decoded.telemetry, [])
        decoded.accelerators = [.init(id: "future.unit", availability: "futureAvailability", reasonCode: "futureReason",
            metric: nil, allocationEvidence: nil, allocationEvidenceKind: nil, fixtureVersion: nil, fixtureSHA256: nil)]
        let roundtrip = try JSONDecoder().decode(MSeriesV11Result.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundtrip.accelerators.first?.availability, "futureAvailability")
        XCTAssertEqual(roundtrip.accelerators.first?.id, "future.unit")
        let status = try JSONDecoder().decode(AppleSiliconIdentificationStatus.self, from: Data(#""futureStatus""#.utf8))
        XCTAssertEqual(status, .unrecognized("futureStatus"))
        XCTAssertEqual(try JSONEncoder().encode(status), Data(#""futureStatus""#.utf8))
    }
    func testReferenceReplacementIsIdempotentAtomicAndPreservesRawHistoryBytes() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        let raw = MSeriesV11TestFixtures.result()
        try await repository.save(raw)
        let originalBytes = try Data(contentsOf: url)
        let provisional = try MSeriesV11TestFixtures.load(MSeriesV11TestFixtures.reference())
        let first = try await repository.recalculate(reference: provisional)
        XCTAssertNil(first.entries.first?.scores.chipScore) // v10 has no v11 GPU peak/tail.
        XCTAssertNil(first.entries.first?.scores.efficiencyScore)
        XCTAssertNotNil(first.entries.first?.scores.componentScores["cpu"])
        let cacheURL = root.appendingPathComponent("benchmark-v11-derived.json")
        let firstBytes = try Data(contentsOf: cacheURL)
        let idempotent = try await repository.recalculate(reference: provisional)
        XCTAssertEqual(idempotent, first)
        XCTAssertEqual(try Data(contentsOf: cacheURL), firstBytes)
        let final = try MSeriesV11TestFixtures.load(MSeriesV11TestFixtures.reference(final: true, scale: 2, version: "synthetic-final"))
        let failing = BenchmarkV7HistoryRepository(storageURL: url, derivedDataWriter: { _, staged in
            try Data("partial write".utf8).write(to: staged)
            throw FixtureError.writeFailed
        })
        do { _ = try await failing.recalculate(reference: final); XCTFail("Expected write failure") } catch FixtureError.writeFailed {}
        XCTAssertEqual(try Data(contentsOf: cacheURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        let replacement = try await repository.recalculate(reference: final)
        XCTAssertEqual(replacement.referenceIdentity.referenceStatus, .final)
        XCTAssertEqual(replacement.previousSnapshots, first.entries)
        XCTAssertNotEqual(replacement.entries.first?.key, first.entries.first?.key)
        XCTAssertEqual(replacement.entries.first?.scores.componentScores["cpu"], 500)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(replacement.entries.first?.originalCompletedAt, raw.completedAt)
        do { _ = try await repository.recalculate(reference: .unavailable); XCTFail("Invalid reference must fail") } catch {}
        let after = try await repository.loadDerivedCache()
        XCTAssertEqual(after, replacement)
    }
}
private enum FixtureError: Error { case writeFailed }
