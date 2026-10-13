import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class HelperReplyBoundaryTests: XCTestCase {
    private func sample() -> PowermetricsSample {
        var timing = PowermetricsSample.Timing(sampleID: UUID().uuidString, helperBootID: UUID().uuidString,
            clockDomain: PowermetricsMonotonicClock.clockDomain, measurementStartMonotonicNs: 1_000_000_000,
            measurementEndMonotonicNs: 2_000_000_000, timestampQuality: .helperMeasured)
        timing.timestampSource = "nativeTimestampEnd+elapsed_ns"
        timing.helperProcessStartMonotonicNs = 900_000_000
        timing.helperProcessEndMonotonicNs = 2_100_000_000
        return .init(cpuMilliwatts: 1_000_000, gpuMilliwatts: 1_000_000, aneMilliwatts: 1_000_000,
            clusters: (0..<16).map { .init(name: "DIE_99_PCPU\($0)", kind: .performance, megahertz: 10_000) },
            gpuMegahertz: 10_000, durationSeconds: 1, timing: timing)
    }

    private func reply() -> FanControlHelperReply {
        .init(operation: .samplePowerMetrics, success: true, message: "Read-only power sampling result.",
            appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample()))
    }

    func testReplyLimitRejectsOversizedValidJSONBeforeDecodingAndKeepsBoundary() throws {
        let value = reply()
        let data = try JSONEncoder().encode(value)
        XCTAssertLessThan(data.count, 8 * 1_024)
        XCTAssertEqual(try FanControlHelperReply.decodeFromTransport(data).validated(for: .samplePowerMetrics), value)
        XCTAssertLessThanOrEqual(FanControlHelperReply.maximumEncodedReplyBytes, PowermetricsPlistParser.maximumOutputBytes)
        let padded = data + Data(repeating: 32, count: FanControlHelperReply.maximumEncodedReplyBytes - data.count)
        XCTAssertEqual(try FanControlHelperReply.decodeFromTransport(padded), value)
        let oversized = padded + Data([32]) // Still valid JSON that the old decoder accepted.
        XCTAssertThrowsError(try FanControlHelperReply.decodeFromTransport(oversized)) {
            XCTAssertEqual($0 as? FanControlHelperProtocolError, .replyTooLarge)
        }
        XCTAssertThrowsError(try FanControlHelperReply.decodeFromTransport(
            Data(repeating: 255, count: FanControlHelperReply.maximumEncodedReplyBytes + 1))) {
            XCTAssertEqual($0 as? FanControlHelperProtocolError, .replyTooLarge, "reject before JSON parsing")
        }
    }

    func testFullControlDTOHasHeadroomAndProductionUsesBoundedDecoder() throws {
        let fans = Dictionary(uniqueKeysWithValues: (0..<16).map { ($0, 10_000) })
        let value = FanControlHelperReply(operation: .getFanCurveRuntimeState, success: true,
            message: String(repeating: "x", count: 512), appliedTargetRPMByFan: fans,
            curveRuntimeState: .init(status: .active, rawTemperature: 99, filteredTemperature: 99,
                calculatedPercentage: 100, appliedPercentage: 100, targetRPMByFan: fans,
                actualRPMByFan: fans, activeProfileID: UUID(), lastSensorUpdate: Date(),
                lastFanWrite: Date(), lastVerification: Date()))
        let data = try JSONEncoder().encode(value)
        XCTAssertLessThan(data.count, 8 * 1_024)
        XCTAssertEqual(try FanControlHelperReply.decodeFromTransport(data), value)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("FanControlHelperReply.decodeFromTransport(replyData)"))
    }

    func testUnknownOversizedAndWrongTypedTimestampSourcesDowngradeWithoutRetainingString() throws {
        let timing = try XCTUnwrap(sample().timing)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(timing)) as? [String: Any])
        for source: Any in ["futureSource", String(repeating: "x", count: 65), String(repeating: "源", count: 30), true, ["bad"]] {
            var object = original; object["timestampSource"] = source
            let decoded = try JSONDecoder().decode(PowermetricsSample.Timing.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.timestampQuality, .requestBracketOnly)
            XCTAssertNil(decoded.measurementStartMonotonicNs); XCTAssertNil(decoded.measurementEndMonotonicNs)
            XCTAssertNil(decoded.timestampSource)
            let diagnostic = sample().withTiming(decoded)
            XCTAssertTrue(diagnostic.isValid)
            XCTAssertNoThrow(try FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "ok",
                appliedTargetRPMByFan: [:], powerSampleResult: .sample(diagnostic)).validated(for: .samplePowerMetrics))
        }
    }

    func testBothKnownSourcesAndLegacyMissingSourceRemainCompatible() throws {
        let timing = try XCTUnwrap(sample().timing)
        for source in ["nativeTimestampStart+elapsed_ns", "nativeTimestampEnd+elapsed_ns"] {
            var known = timing; known.timestampSource = source
            XCTAssertEqual(try JSONDecoder().decode(PowermetricsSample.Timing.self, from: JSONEncoder().encode(known)), known)
        }
        var legacy = timing; legacy.timestampSource = nil
        XCTAssertEqual(try JSONDecoder().decode(PowermetricsSample.Timing.self, from: JSONEncoder().encode(legacy)), legacy)
        var forged = timing; forged.timestampSource = String(repeating: "x", count: 65)
        XCTAssertFalse(forged.isWellFormed, "in-process construction must obey the same whitelist")
    }

    @MainActor
    func testOversizedTransportReplyDegradesCoordinatorWithoutAuthorization() async throws {
        let data = try JSONEncoder().encode(reply())
        let oversized = data + Data(repeating: 32, count: FanControlHelperReply.maximumEncodedReplyBytes + 1 - data.count)
        let coordinator = FanControlCoordinator(defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled,
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.samplePowerMetrics]) { _ in
                try FanControlHelperReply.decodeFromTransport(oversized)
            }, legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("must not register"); throw CancellationError() },
            serviceUnregistrar: { XCTFail("must not unregister"); throw CancellationError() },
            approvalSettingsOpener: { XCTFail("must not authorize") })
        let result = await coordinator.samplePowerMetrics()
        XCTAssertEqual(result, .failure(.unavailable))
    }
}

final class MSeriesV11TelemetryPrivacyTests: XCTestCase {
    private let bootA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let bootB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    private func envelope(compact: Bool = true) -> MSeriesV11Result {
        var value = MSeriesV11Result(sessionID: UUID(), extensionContractHash: MSeriesV11Protocol.contractHash,
            rawPayloadSHA256: "", mode: "pressure10m")
        value.telemetry = (0..<5).map {
            var sample = MSeriesV11WindowTests.telemetry($0)
            sample.helperBootID = $0 < 3 ? bootA : bootB
            return sample
        }
        if compact {
            value.workloadBatches = [MSeriesV11WindowTests.batch(0, 10_000_000_000, work: 1_000)]
            value.efficiencyPoints = [MSeriesV11WindowTests.point(batches: value.workloadBatches, telemetry: value.telemetry)]
        }
        return value
    }

    private func record(_ envelope: MSeriesV11Result) -> BenchmarkV7Result {
        let preflight = MSeriesV11TestFixtures.result().preflight
        return .init(mSeriesV11: envelope,
            session: .init(id: envelope.sessionID, plan: MSeriesV11Protocol.plan(mode: "pressure10m"), storageTarget: preflight.storageTarget),
            preflight: preflight, versions: MSeriesV11Protocol.versions(mode: "pressure10m"), metrics: [], coreScore: nil,
            completedAt: Date(timeIntervalSinceReferenceDate: 10), failure: nil)
    }

    private func legacyRecord(compact: Bool = true) throws -> BenchmarkV7Result {
        var value = envelope(compact: compact)
        // Frozen pre-fix hash semantics: expanded original telemetry with IDs.
        value = value.replacingRawDigest(MSeriesV11Digest.sha256(try MSeriesV11RawPayload.bytes(core: nil, envelope: value)))
        value.metadataWrittenBytes = 1_000; value.writtenBytes = 1_000
        let result = record(value)
        XCTAssertTrue(result.isPersistable)
        return result
    }

    private func assertPrivacy(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], file: file, line: line)
        var evidence = [bytes]
        for record in records {
            let envelope = try XCTUnwrap(record["mSeriesV11"] as? [String: Any], file: file, line: line)
            if let payload = envelope["payload"] as? String {
                evidence.append(try MSeriesV11CompactStorage.expand(XCTUnwrap(Data(base64Encoded: payload)),
                    expectedBytes: XCTUnwrap(envelope["payloadLengthBytes"] as? Int),
                    sha256: XCTUnwrap(envelope["payloadSHA256"] as? String)))
            }
        }
        for data in evidence {
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(json.contains("helperBootID"), file: file, line: line)
            for id in [bootA, bootB] {
                for token in [id, id.lowercased(), id.replacingOccurrences(of: "-", with: ""), Data(id.utf8).base64EncodedString(), MSeriesV11Digest.sha256(Data(id.utf8))] {
                    XCTAssertFalse(json.contains(token), "helper identity or derivative persisted", file: file, line: line)
                }
            }
        }
    }

    func testSealingStripsIdentityBeforeHashAndPreservesEfficiencyAndRunLocalGroups() throws {
        let runtime = envelope()
        let sealed = try MSeriesV11RawPayload.seal(core: nil, envelope: runtime)
        XCTAssertEqual(runtime.telemetry[0].helperBootID, bootA, "runtime alignment evidence stays in memory")
        XCTAssertTrue(sealed.telemetry.allSatisfy { $0.helperBootID == nil })
        XCTAssertEqual(sealed.telemetry.map(\.helperProcessOrdinal), [1, 1, 1, 2, 2])
        XCTAssertTrue(MSeriesV11RawPayload.validates(core: nil, envelope: sealed))
        XCTAssertEqual(sealed.rawPayloadSHA256, MSeriesV11Digest.sha256(try MSeriesV11RawPayload.bytes(core: nil, envelope: sealed)))
        XCTAssertTrue(MSeriesV11Windows.validatesEfficiency(try XCTUnwrap(sealed.efficiencyPoints.first), envelope: sealed))
        XCTAssertEqual(MSeriesV11WindowTests.point(batches: sealed.workloadBatches, telemetry: sealed.telemetry), runtime.efficiencyPoints.first)
        var otherProcess = runtime
        for index in otherProcess.telemetry.indices {
            otherProcess.telemetry[index].helperBootID = index < 3 ? "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC" : "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
        }
        let other = try MSeriesV11RawPayload.seal(core: nil, envelope: otherProcess)
        XCTAssertEqual(other.rawPayloadSHA256, sealed.rawPayloadSHA256, "changing only boot UUIDs must not affect the persisted digest")
        XCTAssertEqual(other.telemetry.map(\.helperProcessOrdinal), sealed.telemetry.map(\.helperProcessOrdinal))
        XCTAssertEqual(try MSeriesV11RawPayload.seal(core: nil, envelope: sealed), sealed, "sealing is idempotent")
    }

    func testNewSavedPlainAndCompressedHistoryContainsNoHelperIDOrDerivative() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        for compact in [false, true] {
            let url = root.appendingPathComponent("new-\(compact).json")
            let repository = BenchmarkV7HistoryRepository(storageURL: url)
            let sealed = try MSeriesV11RawPayload.seal(core: nil, envelope: envelope(compact: compact))
            try await repository.save(record(sealed))
            try assertPrivacy(Data(contentsOf: url))
            let restored = await repository.load()
            XCTAssertEqual(restored.count, 1); XCTAssertTrue(restored.allSatisfy(\.isPersistable))
            let saved = try XCTUnwrap(restored.first?.mSeriesV11)
            XCTAssertEqual(saved.rawPayloadSHA256, sealed.rawPayloadSHA256)
            XCTAssertEqual(saved.telemetry.map(\.helperProcessOrdinal), [1, 1, 1, 2, 2])
            if compact { XCTAssertTrue(MSeriesV11Windows.validatesEfficiency(try XCTUnwrap(saved.efficiencyPoints.first), envelope: saved)) }
        }
    }

    func testLegacyHistoryDecodesWithoutRewritingThenEveryMutationStripsOldRecords() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        for operation in ["save", "replace", "delete"] {
            let url = root.appendingPathComponent("legacy-\(operation).json")
            let old = try legacyRecord()
            let second = try legacyRecord(compact: false)
            let original = try JSONEncoder().encode([old, second])
            try original.write(to: url)
            let repository = BenchmarkV7HistoryRepository(storageURL: url)
            let loaded = await repository.load()
            XCTAssertEqual(loaded.count, 2)
            XCTAssertEqual(loaded.first?.mSeriesV11?.rawPayloadSHA256, old.mSeriesV11?.rawPayloadSHA256)
            XCTAssertEqual(loaded.first?.mSeriesV11?.telemetry.first?.helperBootID, bootA)
            XCTAssertEqual(try Data(contentsOf: url), original, "read does not mutate legacy evidence")
            if operation == "save" { try await repository.save(record(MSeriesV11RawPayload.seal(core: nil, envelope: envelope()))) }
            else if operation == "replace" { try await repository.replace(recordID: XCTUnwrap(old.recordID), with: record(MSeriesV11RawPayload.seal(core: nil, envelope: envelope()))) }
            else { let deleted = try await repository.delete(recordID: XCTUnwrap(old.recordID)); XCTAssertTrue(deleted) }
            try assertPrivacy(Data(contentsOf: url))
            let saved = await repository.load()
            XCTAssertFalse(saved.isEmpty); XCTAssertTrue(saved.allSatisfy(\.isPersistable))
            let surviving = try XCTUnwrap(saved.first { $0.recordID == second.recordID }?.mSeriesV11)
            XCTAssertNotEqual(surviving.rawPayloadSHA256, second.mSeriesV11?.rawPayloadSHA256)
            XCTAssertTrue(MSeriesV11RawPayload.validates(core: nil, envelope: surviving))
        }
    }

    func testPrivacyRewriteStillRejectsV11WithoutRecordIDBesideLegacyNilID() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("nil-identity.json")
        func withoutRecordID(_ value: BenchmarkV7Result) throws -> BenchmarkV7Result {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object.removeValue(forKey: "recordID")
            return try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let legacy = try withoutRecordID(MSeriesV11TestFixtures.result())
        let original = try JSONEncoder().encode([legacy]); try original.write(to: url)
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        let invalid = try withoutRecordID(record(MSeriesV11RawPayload.seal(core: nil, envelope: envelope())))
        do { try await repository.save(invalid); XCTFail("v11 cannot bypass its record identity/write budget guard") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        let loaded = await repository.load()
        XCTAssertEqual(loaded, [legacy])
    }
}
