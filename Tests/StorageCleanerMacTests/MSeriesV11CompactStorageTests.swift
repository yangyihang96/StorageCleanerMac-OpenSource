import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11CompactStorageTests: XCTestCase {
    private func envelope() -> MSeriesV11Result {
        var value = MSeriesV11Result(sessionID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            extensionContractHash: MSeriesV11TestFixtures.extensionHash, rawPayloadSHA256: "", mode: "pressure10m")
        value.workloadBatches = [.init(stageID: "pressure.gpu", startMonotonicNs: 1_000_000_000,
            endMonotonicNs: 1_050_000_000, workUnits: 10, gpuElapsedSeconds: 0.025, checksum: 7,
            clockDomain: MSeriesV11Windows.clockDomain)]
        return value
    }

    func testCanonicalRawSHAStillUsesOriginalExpandedJSONAndLegacyRecordsDecode() throws {
        let value = envelope()
        // Independent oracle for the pre-fix2 synthesized JSON, not the new encoder.
        let original: [String: Any] = ["envelope": [
            "schema": "mseries-result-v11", "plan": "mseries-pressure-v11", "mode": "pressure10m",
            "sessionID": "12345678-1234-1234-1234-123456789ABC", "coreContractHash": MSeriesProtocol.contractHash,
            "extensionContractHash": MSeriesV11TestFixtures.extensionHash,
            "scoringContractHash": MSeriesScoringV11.scoringContractHash, "rawPayloadSHA256": "",
            "efficiencyPoints": [], "accelerators": [], "legacyExtensions": [], "perStageEnvironment": [:],
            "telemetry": [], "missingReasons": [], "writtenBytes": 0,
            "workloadBatches": [["stageID": "pressure.gpu", "startMonotonicNs": 1_000_000_000,
                "endMonotonicNs": 1_050_000_000, "workUnits": 10, "gpuElapsedSeconds": 0.025,
                "checksum": 7, "clockDomain": MSeriesV11Windows.clockDomain]]
        ]]
        // JSONSerialization emits 0.025000000000000001 on this SDK. The frozen
        // JSONEncoder raw-byte contract uses the shortest round-trip token 0.025.
        let expected = Data("""
        {"envelope":{"accelerators":[],"coreContractHash":"\(MSeriesProtocol.contractHash)","efficiencyPoints":[],"extensionContractHash":"\(MSeriesV11TestFixtures.extensionHash)","legacyExtensions":[],"missingReasons":[],"mode":"pressure10m","perStageEnvironment":{},"plan":"mseries-pressure-v11","rawPayloadSHA256":"","schema":"mseries-result-v11","scoringContractHash":"\(MSeriesScoringV11.scoringContractHash)","sessionID":"12345678-1234-1234-1234-123456789ABC","telemetry":[],"workloadBatches":[{"checksum":7,"clockDomain":"mach-continuous-v1","endMonotonicNs":1050000000,"gpuElapsedSeconds":0.025,"stageID":"pressure.gpu","startMonotonicNs":1000000000,"workUnits":10}],"writtenBytes":0}}
        """.utf8)
        let actual = try MSeriesV11RawPayload.bytes(core: nil, envelope: value)
        XCTAssertEqual(actual, expected, "actual=\(String(decoding: actual, as: UTF8.self)) expected=\(String(decoding: expected, as: UTF8.self))")
        let sealed = try MSeriesV11RawPayload.seal(core: nil, envelope: value)
        XCTAssertEqual(sealed.rawPayloadSHA256, MSeriesV11Digest.sha256(expected))
        let legacy = try JSONSerialization.data(withJSONObject: try XCTUnwrap(original["envelope"]))
        let decodedLegacy = try JSONDecoder().decode(MSeriesV11Result.self, from: legacy)
        XCTAssertEqual(decodedLegacy.workloadBatches, value.workloadBatches)
        let restored = try JSONDecoder().decode(MSeriesV11Result.self, from: JSONEncoder().encode(sealed))
        XCTAssertEqual(restored.rawPayloadSHA256, sealed.rawPayloadSHA256)
        XCTAssertTrue(MSeriesV11RawPayload.validates(core: nil, envelope: restored))
    }

    func testArchiveRetainsExactIntegerDoubleAndAllEvidenceAndLedgerDoesNotChangeBody() throws {
        var value = envelope()
        let start = UInt64.max - 100_000_000
        value.workloadBatches.append(.init(stageID: "pressure.gpu", startMonotonicNs: start,
            endMonotonicNs: start + 50_000_000, workUnits: Double.pi.nextUp,
            gpuElapsedSeconds: 0.025.nextUp, checksum: UInt64.max, clockDomain: MSeriesV11Windows.clockDomain))
        value.perStageEnvironment = ["pressure.gpu": [.init(assessmentVersion: "all-observations", startMonotonicNs: start)]]
        value.telemetry = [MSeriesV11WindowTests.telemetry(0)]
        value = try MSeriesV11RawPayload.seal(core: nil, envelope: value)
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(value)
        let restored = try JSONDecoder().decode(MSeriesV11Result.self, from: bytes)
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.workloadBatches.last?.workUnits.bitPattern, Double.pi.nextUp.bitPattern)
        XCTAssertEqual(restored.workloadBatches.last?.gpuElapsedSeconds?.bitPattern, 0.025.nextUp.bitPattern)
        var ledgerChanged = value
        ledgerChanged.metadataWrittenBytes = 2_097_152
        ledgerChanged.writtenBytes = 2_097_152
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(ledgerChanged)) as? [String: Any])
        XCTAssertEqual(first["payload"] as? String, second["payload"] as? String)
        XCTAssertEqual(first["payloadSHA256"] as? String, second["payloadSHA256"] as? String)
        XCTAssertTrue(MSeriesV11RawPayload.validates(core: nil, envelope: ledgerChanged))
    }

    func testCorruptArchiveWrongLengthHashAndOversizedExpansionAreRejected() throws {
        let bytes = try JSONEncoder().encode(envelope())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let length = try XCTUnwrap(original["payloadLengthBytes"] as? Int)
        let mutations: [(String, Any)] = [("payloadLengthBytes", length - 1), ("payloadLengthBytes", length + 1),
            ("payloadLengthBytes", 64 * 1024 * 1024 + 1), ("payloadSHA256", String(repeating: "0", count: 64)),
            ("payload", Data("not-an-lzfse-stream".utf8).base64EncodedString()), ("payloadEncoding", "unknown")]
        for (key, after) in mutations {
            var corrupted = original; corrupted[key] = after
            XCTAssertThrowsError(try JSONDecoder().decode(MSeriesV11Result.self,
                from: JSONSerialization.data(withJSONObject: corrupted)), key)
        }
    }

    func testBudgetForecastDoesNotMultiplyFixedIdentityEvidenceByBatchFrequency() throws {
        var value = envelope()
        var state: UInt64 = 77
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        let identity = String(decoding: (0..<20_000).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return alphabet[Int((state >> 32) % UInt64(alphabet.count))]
        }, as: UTF8.self)
        value.preflight = .init(assessmentVersion: identity)
        let forecast = try MSeriesV11EvidenceBudget.forecast(value, core: nil, measuredSeconds: 5, plannedSeconds: 600)
        XCTAssertLessThan(forecast.projectedStorageBytes, 768 * 1024,
            "fixed evidence is retained once; multiplying it by 120 would falsely refuse an otherwise small run")
        XCTAssertGreaterThan(forecast.currentStorageBytes, 10_000)
        XCTAssertGreaterThanOrEqual(forecast.projectedStorageBytes, forecast.currentStorageBytes)
    }
}
