import AgentGatewayCore
import AgentShared
import Darwin
import Foundation
import XCTest

/// D263 approvals, D268 limits and D264 access records.
final class AgentGatewayRecordsTests: XCTestCase {
    private let claude = AgentClientIdentity(kind: .signed, identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW", cdhash: nil,
                                             executablePath: "~/.local/bin/claude", displayName: "claude")

    // MARK: Approvals

    func testUnknownClientPromptsAtMostOncePerTenMinutes() {
        let registry = AgentClientRegistry(storage: .memory())
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(registry.decision(for: claude))
        XCTAssertTrue(registry.notePending(claude, at: start))
        XCTAssertFalse(registry.notePending(claude, at: start.addingTimeInterval(599)))
        XCTAssertTrue(registry.notePending(claude, at: start.addingTimeInterval(601)))
        XCTAssertEqual(registry.pending.map(\.identity), [claude])
    }

    func testDecisionsPersistBindToTheSignerAndCanBeRevoked() throws {
        let storage = AgentClientStorage.memory()
        let registry = AgentClientRegistry(storage: storage)
        _ = registry.notePending(claude, at: Date(timeIntervalSince1970: 1))
        registry.decide(claude, .readOnly, at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(registry.pending.isEmpty)

        var moved = claude
        moved.executablePath = "~/.local/share/claude/versions/3.1/claude"
        let reopened = AgentClientRegistry(storage: storage)
        XCTAssertEqual(reopened.decision(for: moved), .readOnly, "Same signer in a new folder keeps its approval")
        reopened.markUsed(moved, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(reopened.records.first?.lastUsedAt, Date(timeIntervalSince1970: 50))

        reopened.revoke(bindingKey: claude.bindingKey)
        XCTAssertNil(AgentClientRegistry(storage: storage).decision(for: claude))

        reopened.decide(claude, .denied, at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(AgentClientRegistry(storage: storage).decision(for: claude), .denied)
    }

    func testDamagedStorageStartsEmpty() {
        let storage = AgentClientStorage.memory(Data("not json".utf8))
        XCTAssertTrue(AgentClientRegistry(storage: storage).records.isEmpty)
    }

    // MARK: Limits

    func testReadsAreLimitedPerClientPerSecondAndPerMinute() {
        var limiter = AgentRateLimiter(perSecond: 20, perMinute: 600)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual((0..<21).filter { _ in limiter.admit("a", at: start) }.count, 20)
        XCTAssertTrue(limiter.admit("b", at: start), "Each client has its own budget")
        XCTAssertTrue(limiter.admit("a", at: start.addingTimeInterval(1.01)))

        var minute = AgentRateLimiter(perSecond: 20, perMinute: 600)
        var admitted = 0
        for second in 0..<40 { for _ in 0..<20 where minute.admit("a", at: start.addingTimeInterval(Double(second))) { admitted += 1 } }
        XCTAssertEqual(admitted, 600)
        XCTAssertTrue(minute.admit("a", at: start.addingTimeInterval(60.5)), "The window slides")
    }

    // MARK: Access log

    func testAccessLogHasNoArgumentsOrResultsAndIsPrivate() throws {
        let root = try AgentTestDirectory.make(self)
        let log = AgentAccessLog(fileURL: root.appendingPathComponent("access.jsonl"), clock: { Date(timeIntervalSince1970: 5) })
        log.append(.init(time: Date(timeIntervalSince1970: 5), client: "claude", clientKey: claude.bindingKey, tool: "list_results",
                         level: .read, outcome: .refused, reason: .approvalRequired))
        let line = try String(contentsOf: root.appendingPathComponent("access.jsonl"), encoding: .utf8)
        let object = try JSONDecoder().decode(AgentJSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(Set(object.objectValue?.keys.map { $0 } ?? []),
                       ["time", "client", "clientKey", "tool", "level", "outcome", "reason"])
        XCTAssertEqual(log.entries().map(\.tool), ["list_results"])
        var status = stat()
        XCTAssertEqual(stat(root.appendingPathComponent("access.jsonl").path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
    }

    func testAccessLogKeepsTheNewestEntriesWithinThirtyDaysAndSkipsDamage() throws {
        let root = try AgentTestDirectory.make(self)
        let url = root.appendingPathComponent("access.jsonl")
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = AgentAccessLog(fileURL: url, clock: { now }, maximumEntries: 3, trimEvery: 1_000)
        old.append(entry("stale", at: now.addingTimeInterval(-31 * 86_400)))
        for index in 0..<4 { old.append(entry("t\(index)", at: now.addingTimeInterval(Double(index)))) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken\n".utf8))
        try handle.close()
        XCTAssertEqual(old.entries().map(\.tool), ["stale", "t0", "t1", "t2", "t3"], "Damaged lines are skipped")

        let reopened = AgentAccessLog(fileURL: url, clock: { now }, maximumEntries: 3, trimEvery: 1_000)
        XCTAssertEqual(reopened.entries().map(\.tool), ["t1", "t2", "t3"], "Opening trims to 30 days and the newest entries")
    }

    private func entry(_ tool: String, at time: Date) -> AgentAccessLogEntry {
        .init(time: time, client: "c", clientKey: "k", tool: tool, level: .read, outcome: .allowed)
    }
}
