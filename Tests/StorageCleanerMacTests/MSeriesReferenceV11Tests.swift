import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesReferenceV11Tests: XCTestCase {
    private func mutate(_ body: (inout [String: Any]) throws -> Void) throws -> MSeriesReferenceV11.Loaded {
        let reference = MSeriesV11TestFixtures.reference()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(reference)) as? [String: Any])
        try body(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MSeriesReferenceV11.load(bytes: bytes, manifest: .init(version: reference.version, sha256: MSeriesV11Digest.sha256(bytes)),
            sourceBytes: ["synthetic.json": MSeriesV11TestFixtures.artifact])
    }
    func testReferenceRequires8IndependentRunsTwoCooledSessionsAndExactContracts() throws {
        XCTAssertNotNil(try MSeriesV11TestFixtures.load(MSeriesV11TestFixtures.reference()).reference)
        for key in ["coreContractHash", "extensionContractHash", "scoringContractHash", "scoringVersion", "powerPolicy", "timingPolicy"] {
            XCTAssertNil(try mutate { $0[key] = "bad" }.reference, key)
        }
        XCTAssertNil(try mutate { $0["provisionalAgainst"] = NSNull() }.reference)
        XCTAssertNil(try mutate { object in
            var sessions = object["sessions"] as! [[String: Any]]
            sessions.removeLast(); object["sessions"] = sessions
        }.reference)
        XCTAssertNil(try mutate { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var runs = sessions[1]["runs"] as! [[String: Any]]
            let formatter = ISO8601DateFormatter()
            runs[0]["startedAt"] = formatter.string(from: Date(timeIntervalSinceReferenceDate: 400))
            runs[0]["completedAt"] = formatter.string(from: Date(timeIntervalSinceReferenceDate: 450))
            sessions[1]["runs"] = runs; object["sessions"] = sessions
        }.reference)
        XCTAssertNil(try mutate { object in
            var ids = object["independentRunIDs"] as! [String]
            ids[1] = ids[0]; object["independentRunIDs"] = ids
        }.reference)
        XCTAssertNil(try mutate { object in
            var medians = object["medians"] as! [String: Any]
            medians.removeValue(forKey: "power.gpu.peak"); object["medians"] = medians
        }.reference)
    }
    func testByteAndSourceArtifactHashesMustMatchBeforeDecoding() throws {
        let reference = MSeriesV11TestFixtures.reference()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(reference)
        let manifest = MSeriesReferenceV11.Manifest(version: reference.version, sha256: MSeriesV11Digest.sha256(bytes))
        XCTAssertNil(MSeriesReferenceV11.load(bytes: bytes + Data([10]), manifest: manifest,
            sourceBytes: ["synthetic.json": MSeriesV11TestFixtures.artifact]).reference)
        XCTAssertNil(MSeriesReferenceV11.load(bytes: bytes, manifest: manifest,
            sourceBytes: ["synthetic.json": Data("corrupt".utf8)]).reference)
        XCTAssertNil(MSeriesReferenceV11.load(bytes: bytes, manifest: manifest, sourceBytes: [:]).reference)
    }
}
