import FileOperationShared
import Foundation
import XCTest

final class SystemCacheContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func request(expiresAt: Date? = nil) -> SystemCacheClearRequest {
        .init(caches: [.coreSymbolication], directories: [.init(cache: .coreSymbolication, device: 1, inode: 2)],
              expiresAt: expiresAt ?? now.addingTimeInterval(60))
    }
    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> SystemCacheClearRequest {
        try SystemCacheClearRequest.decode(JSONSerialization.data(withJSONObject: object))
    }
    func testRoundTripAndFreshness() throws {
        let expected = request()
        XCTAssertEqual(try SystemCacheClearRequest.decode(JSONEncoder().encode(expected)), expected)
        try expected.validateFreshness(receivedAt: now)
        XCTAssertThrowsError(try request(expiresAt: now).validateFreshness(receivedAt: now))
        XCTAssertThrowsError(try request(expiresAt: now.addingTimeInterval(-1)).validateFreshness(receivedAt: now))
        XCTAssertThrowsError(try request(expiresAt: now.addingTimeInterval(66)).validateFreshness(receivedAt: now))
    }
    func testUnknownDuplicateAndEmptyIdentifiersAreRejected() throws {
        for caches: [String] in [[], ["unknown"], ["coreSymbolication", "coreSymbolication"],
                                 ["coreSymbolication", "iconServices", "coreSymbolication"]] {
            var json = try object(); json["caches"] = caches
            XCTAssertThrowsError(try decode(json), "\(caches)")
        }
    }
    func testPathsAndUnknownFieldsAtEitherLevelAreRejected() throws {
        for key in ["path", "directoryPath", "applicationPath", "anything"] {
            var json = try object(); json[key] = "/outside"
            XCTAssertThrowsError(try decode(json))
            json = try object()
            var directories = try XCTUnwrap(json["directories"] as? [[String: Any]])
            directories[0][key] = "/outside"; json["directories"] = directories
            XCTAssertThrowsError(try decode(json))
        }
    }
    func testOversizedMalformedAndMismatchedIdentitiesAreRejected() throws {
        XCTAssertThrowsError(try SystemCacheClearRequest.decode(Data(repeating: 32, count: SystemCacheClearRequest.maximumBytes + 1)))
        XCTAssertThrowsError(try SystemCacheClearRequest.decode(Data()))
        var json = try object(); json["directories"] = []
        XCTAssertThrowsError(try decode(json))
        json = try object(); json["directories"] = [["cache": "iconServices", "device": 1, "inode": 2]]
        XCTAssertThrowsError(try decode(json))
        json = try object(); json["directories"] = [["cache": "coreSymbolication", "device": 1, "inode": 0]]
        XCTAssertThrowsError(try decode(json))
    }
    func testUnapprovedReplayExpiredAndDifferentCommitsAreRejected() throws {
        let original = request()
        var gate = SystemCacheCommitGate()
        try gate.reserve(original, receivedAt: now)
        XCTAssertThrowsError(try gate.consume(original, now: now))
        // A rejected commit also consumes the pending operation.
        XCTAssertThrowsError(try gate.approve(original, now: now))
        XCTAssertThrowsError(try gate.reserve(original, receivedAt: now))
        gate = SystemCacheCommitGate()
        try gate.reserve(original, receivedAt: now)
        try gate.approve(original, now: now.addingTimeInterval(120))
        try gate.consume(original, now: now.addingTimeInterval(134))
        XCTAssertThrowsError(try gate.consume(original, now: now.addingTimeInterval(134)))
        gate = SystemCacheCommitGate()
        try gate.reserve(original, receivedAt: now); try gate.approve(original, now: now)
        XCTAssertThrowsError(try gate.consume(original, now: now.addingTimeInterval(15)))
        gate = SystemCacheCommitGate()
        try gate.reserve(original, receivedAt: now); try gate.approve(original, now: now)
        XCTAssertThrowsError(try gate.consume(request(), now: now))
        XCTAssertThrowsError(try gate.consume(original, now: now))
    }
    func testEveryOperationRequiresAnUnsharedZeroTimeoutAdministratorRight() {
        let rule: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 0]
        XCTAssertTrue(SystemCacheAuthorizationPolicy.isPerOperationAdmin(rule))
        for (key, value): (String, Any) in [("group", "everyone"), ("timeout", 300), ("shared", true), ("authenticate-user", false), ("class", "allow")] {
            var loose = rule; loose[key] = value
            XCTAssertFalse(SystemCacheAuthorizationPolicy.isPerOperationAdmin(loose))
        }
    }
    func testClockRollbackCannotApproveAndInvalidatesThePendingRequest() throws {
        let original = request()
        var gate = SystemCacheCommitGate()
        try gate.reserve(original, receivedAt: now)
        XCTAssertThrowsError(try gate.approve(original, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try gate.consume(original, now: now))
    }
    func testSourceGuardsWhitelistAndReadOnlyInventory() throws {
        let code = try SwiftSourceScanning.sources()
        for cache in SystemCacheID.allCases {
            // The path is constructed from the contract here, never copied into a client.
            let literal = "\"" + cache.directoryPath + "\""
            let files = code.filter { $0.value.contains(literal) }.keys.sorted()
            XCTAssertEqual(files, ["Sources/FileOperationShared/SystemCacheContract.swift"])
        }
        let helper = try XCTUnwrap(code["Sources/FileOperationHelper/SystemCaches.swift"])
        for forbidden in ["removeItem", "Process(", "system(", "popen"] { XCTAssertFalse(helper.contains(forbidden)) }
        XCTAssertTrue(helper.contains("identity.cache.directoryPath"))
        XCTAssertTrue(helper.contains("SystemCacheClearRequest.decode"))
        let client = try SwiftSourceScanning.body(of: "final class SystemCacheService:",
            in: XCTUnwrap(code["Sources/StorageCleanerMac/Services/SystemCacheService.swift"]))
        let inventory = try SwiftSourceScanning.body(of: "func inventory()", in: client)
        for forbidden in ["prepareHelper", "authorize(", "AuthorizationCopyRights", "register("] {
            XCTAssertFalse(inventory.contains(forbidden), forbidden)
        }
        XCTAssertTrue(inventory.contains("checkBuild(connection)"))
        // Integration review (old value: required the `helperIsRunning` PID gate):
        // like D177, a registered helper is started on demand; only the bundled one.
        XCTAssertTrue(inventory.contains("forResource: \"StorageCleanerFileOperationHelper\""))
        let clear = try SwiftSourceScanning.body(of: "func clear(_ directories:", in: client)
        let prepare = try XCTUnwrap(clear.range(of: "prepareSystemCacheClear?"))
        let recheck = try XCTUnwrap(clear.range(of: "proxy.systemCacheInventory?"))
        let commit = try XCTUnwrap(clear.range(of: "commitSystemCacheClear?"))
        XCTAssertLessThan(prepare.lowerBound, recheck.lowerBound)
        XCTAssertLessThan(recheck.lowerBound, commit.lowerBound)
        XCTAssertTrue(clear.contains("coordinator.acquire(owner: .cleanup)"))
        XCTAssertTrue(clear.contains("authorization.destroy()"))
        XCTAssertLessThan(try XCTUnwrap(clear.range(of: "trustedBundledHelper(bundled)")).lowerBound,
                          try XCTUnwrap(clear.range(of: "prepareHelper()")).lowerBound)
    }
}
