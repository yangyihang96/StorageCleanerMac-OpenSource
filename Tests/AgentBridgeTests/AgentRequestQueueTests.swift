import AgentGatewayCore
import AgentShared
import Foundation
import XCTest

/// D262: a proposal only ever becomes an entry here. Nothing in this queue
/// executes anything: the App's confirmation page does, after the user acts.
final class AgentRequestQueueTests: XCTestCase {
    private let claude = AgentClientIdentity(kind: .signed, identifier: "com.anthropic.claude-code", team: "T", cdhash: nil,
                                             executablePath: "~/.local/bin/claude", displayName: "claude")
    private let codex = AgentClientIdentity(kind: .signed, identifier: "com.openai.codex", team: "U", cdhash: nil,
                                            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", displayName: "Codex")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func proposal(_ module: String = "junk", reason: String? = nil) -> AgentProposal {
        .init(tool: "propose_move_to_trash", module: module, summary: "把 12 项（3.2 GB）移到废纸篓", reason: reason)
    }

    func testAProposalWaitsForTheUserAndExpiresAfterFifteenMinutes() throws {
        let queue = AgentRequestQueue()
        let request = try queue.add(proposal(reason: "磁盘快满了"), from: claude, at: start)
        XCTAssertEqual(request.state, .waitingForUser)
        XCTAssertEqual(request.clientName, "claude")
        XCTAssertEqual(request.reason, "磁盘快满了")
        XCTAssertEqual(request.expiresAt, start.addingTimeInterval(900))
        XCTAssertEqual(queue.waitingCount(at: start), 1, "What the menu bar badge shows")

        XCTAssertEqual(try queue.request(request.id, for: claude, at: start.addingTimeInterval(899)).state, .waitingForUser)
        XCTAssertEqual(try queue.request(request.id, for: claude, at: start.addingTimeInterval(900)).state, .expired)
        XCTAssertEqual(queue.waitingCount(at: start.addingTimeInterval(900)), 0)
        XCTAssertThrowsError(try queue.beginConfirmation(request.id, at: start.addingTimeInterval(901)),
                             "An expired request can no longer be confirmed") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .unknownItem)
        }
    }

    func testLimitsPerClientAndPerModule() throws {
        let queue = AgentRequestQueue()
        _ = try queue.add(proposal("junk"), from: claude, at: start)
        XCTAssertThrowsError(try queue.add(proposal("junk"), from: claude, at: start), "One at a time per module") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .busy)
        }
        XCTAssertThrowsError(try queue.add(proposal("junk"), from: codex, at: start), "Also across clients") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .busy)
        }
        _ = try queue.add(proposal("large_files"), from: claude, at: start)
        _ = try queue.add(proposal("duplicates"), from: claude, at: start)
        XCTAssertThrowsError(try queue.add(proposal("downloads"), from: claude, at: start), "Three waiting per client") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .busy)
        }
        XCTAssertNoThrow(try queue.add(proposal("downloads"), from: codex, at: start))
        XCTAssertNoThrow(try queue.add(proposal("junk"), from: codex, at: start.addingTimeInterval(901)),
                         "An expired request frees its module")
    }

    func testAClientSeesAndCancelsOnlyItsOwnRequests() throws {
        let queue = AgentRequestQueue()
        let mine = try queue.add(proposal("junk"), from: claude, at: start)
        let theirs = try queue.add(proposal("large_files"), from: codex, at: start)
        XCTAssertEqual(queue.requests(for: claude, at: start).map(\.id), [mine.id])
        XCTAssertThrowsError(try queue.request(theirs.id, for: claude, at: start), "Another client's number reads as unknown") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .unknownItem)
        }
        XCTAssertThrowsError(try queue.cancel(theirs.id, by: claude, at: start))
        XCTAssertEqual(try queue.cancel(mine.id, by: claude, at: start).state, .cancelled)
        XCTAssertThrowsError(try queue.cancel(mine.id, by: claude, at: start), "Only a waiting request can be withdrawn")
        XCTAssertEqual(queue.waitingCount(at: start), 1)
    }

    func testTheUserDecidesAndTheOutcomeIsReadableAfterwards() throws {
        let queue = AgentRequestQueue()
        let rejected = try queue.add(proposal("junk"), from: claude, at: start)
        XCTAssertEqual(try queue.reject(rejected.id, at: start).state, .rejected)

        let accepted = try queue.add(proposal("large_files"), from: claude, at: start)
        XCTAssertEqual(try queue.beginConfirmation(accepted.id, at: start).state, .confirming)
        XCTAssertThrowsError(try queue.cancel(accepted.id, by: claude, at: start), "Too late once the user has it open")
        XCTAssertEqual(try queue.finish(accepted.id, outcome: "已移到废纸篓 12 项", failed: false, at: start).state, .completed)
        let read = try queue.request(accepted.id, for: claude, at: start.addingTimeInterval(3_000))
        XCTAssertEqual(read.outcome, "已移到废纸篓 12 项")
        XCTAssertEqual(read.state, .completed, "A confirmed request is past expiry and stays completed")

        let failed = try queue.add(proposal("duplicates"), from: claude, at: start)
        _ = try queue.beginConfirmation(failed.id, at: start)
        XCTAssertEqual(try queue.finish(failed.id, outcome: "用户取消了验证", failed: true, at: start).state, .failed)
    }

    func testSwitchOffAndRejectAllVoidWhatIsWaitingOnly() throws {
        let queue = AgentRequestQueue()
        let one = try queue.add(proposal("junk"), from: claude, at: start)
        let two = try queue.add(proposal("large_files"), from: codex, at: start)
        let open = try queue.add(proposal("duplicates"), from: codex, at: start)
        _ = try queue.beginConfirmation(open.id, at: start)
        XCTAssertEqual(queue.rejectAll(at: start), 2)
        XCTAssertEqual(try queue.request(one.id, for: claude, at: start).state, .rejected)
        XCTAssertEqual(try queue.request(two.id, for: codex, at: start).state, .rejected)
        XCTAssertEqual(try queue.request(open.id, for: codex, at: start).state, .confirming, "The page the user has open is theirs")

        let later = try queue.add(proposal("junk"), from: claude, at: start)
        queue.voidAll(at: start)
        XCTAssertEqual(try queue.request(later.id, for: claude, at: start).state, .voided)
        XCTAssertEqual(try queue.request(open.id, for: codex, at: start).state, .voided,
                       "D265/D267: turning off or quitting voids even a request being looked at")
        XCTAssertThrowsError(try queue.finish(open.id, outcome: "x", failed: false, at: start))
    }

    func testOldFinishedRequestsAreForgotten() throws {
        let queue = AgentRequestQueue(maximumFinished: 2)
        var ids: [String] = []
        for index in 0..<4 {
            let request = try queue.add(proposal("junk"), from: claude, at: start.addingTimeInterval(Double(index)))
            _ = try queue.reject(request.id, at: start.addingTimeInterval(Double(index)))
            ids.append(request.id)
        }
        XCTAssertEqual(Set(ids).count, 4, "Numbers are never reused")
        XCTAssertEqual(queue.requests(for: claude, at: start.addingTimeInterval(10)).map(\.id), [ids[2], ids[3]])
        XCTAssertThrowsError(try queue.request(ids[0], for: claude, at: start.addingTimeInterval(10)))
    }

    func testRequestsReadAsPlainResultsWithoutTheClientKey() throws {
        let queue = AgentRequestQueue()
        let request = try queue.add(proposal("junk", reason: "r"), from: claude, at: start)
        let json = request.json
        XCTAssertEqual(json["id"], .string(request.id))
        XCTAssertEqual(json["state"], "waiting_for_user")
        XCTAssertEqual(json["tool"], "propose_move_to_trash")
        XCTAssertEqual(json["summary"], "把 12 项（3.2 GB）移到废纸篓")
        XCTAssertEqual(json["expires_at"], "1970-01-12T14:01:40Z")
        XCTAssertNil(json["client_key"])
    }

    // MARK: The router answers from the queue

    func testRouterReadsAndWithdrawsFromTheQueue() async throws {
        let fixture = try RouterFixture(self)
        fixture.registry.decide(claude, .readOnly, at: Date())
        fixture.registry.decide(codex, .propose, at: Date())
        let router = fixture.router()
        let waiting = try fixture.queue.add(proposal("junk"), from: claude, at: fixture.now)

        var response = await router.handle(.init(id: "1", tool: "list_requests", arguments: [:], surface: .mcp), from: claude)
        XCTAssertEqual(response.result?["items"]?[0]?["id"], .string(waiting.id))
        response = await router.handle(.init(id: "2", tool: "list_requests", arguments: [:], surface: .mcp), from: codex)
        XCTAssertEqual(response.result, ["items": []], "Requests of other clients stay out of sight")
        response = await router.handle(.init(id: "3", tool: "get_request", arguments: ["request_id": .string(waiting.id)], surface: .mcp),
                                       from: claude)
        XCTAssertEqual(response.result?["request"]?["state"], "waiting_for_user")
        response = await router.handle(.init(id: "4", tool: "cancel_request", arguments: ["request_id": .string(waiting.id)], surface: .mcp),
                                       from: codex)
        XCTAssertEqual(response.refusal?.reason, .unknownItem)
        response = await router.handle(.init(id: "5", tool: "cancel_request", arguments: ["request_id": .string(waiting.id)], surface: .mcp),
                                       from: claude)
        XCTAssertEqual(response.result?["request"]?["state"], "cancelled", "Even a read-only client may withdraw its own")
    }
}
