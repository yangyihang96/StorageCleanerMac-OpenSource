import AgentBridgeCore
import AgentGatewayCore
import AgentShared
import Darwin
import FileOperationShared
import Foundation
import XCTest

/// D265: the switch is off by default; on listens, off hangs up at once. D263:
/// a place that cannot work keeps the gateway off and says why, never moving
/// the socket somewhere else quietly.
final class AgentGatewaySwitchTests: XCTestCase {
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.apple.Terminal", team: nil, cdhash: nil,
                                             executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                                             displayName: "Terminal")

    private func gateway(_ data: URL, policy: @escaping @Sendable () -> (@Sendable (UpdateAskpassKernelPeer) -> Bool)? = { { $0.pid == getpid() } },
                         identified: Bool = true) -> AgentGateway {
        let client = client
        return AgentGateway(.init(dataDirectory: data, peerAuthorization: policy, identifyClient: { _ in identified ? client : nil },
                                  clientStorage: .memory(), provider: RecordingProvider(), onApprovalNeeded: { _ in }))
    }

    private func transport(_ data: URL, enabled: Bool?) -> AgentSocketTransport {
        AgentSocketTransport(socketPath: AgentSocketLocation.socketPath(dataDirectory: data),
                             authorizeApp: { $0.pid == getpid() }, interfaceEnabled: { enabled })
    }

    private let overview = AgentChannelRequest(id: "1", tool: "get_overview", arguments: [:], surface: .mcp)

    func testOffByDefaultListensOnlyWhenOnAndHangsUpWhenOff() async throws {
        let data = try AgentTestDirectory.make(self)
        let gateway = gateway(data)
        let path = AgentSocketLocation.socketPath(dataDirectory: data)
        var status = await gateway.status
        XCTAssertEqual(status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "D265: nothing listens until the user turns it on")

        await gateway.setEnabled(true)
        status = await gateway.status
        XCTAssertEqual(status, .listening)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        var permissions = stat()
        XCTAssertEqual(lstat(path, &permissions), 0)
        XCTAssertEqual(permissions.st_mode & 0o777, 0o600)

        let bridge = transport(data, enabled: false)
        let refused = await bridge.call(overview)
        XCTAssertEqual(refused, .refused(AgentRefusal(.approvalRequired)), "Reached the router: on, and the client is undecided")

        gateway.registry.decide(client, .readOnly, at: Date())
        let allowed = await bridge.call(overview)
        guard case .result = allowed else { return XCTFail("\(allowed)") }

        await gateway.setEnabled(false)
        status = await gateway.status
        XCTAssertEqual(status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let afterOff = await bridge.call(overview)
        XCTAssertEqual(afterOff, .refused(AgentRefusal(.interfaceOff)), "A connected bridge is told the interface is off")

        await gateway.setEnabled(true)
        let again = await transport(data, enabled: true).call(overview)
        guard case .result = again else { return XCTFail("\(again)") }
        await gateway.setEnabled(false)
    }

    func testRepeatingTheSameSwitchChangesNothing() async throws {
        let data = try AgentTestDirectory.make(self)
        let gateway = gateway(data)
        await gateway.setEnabled(true)
        let bridge = transport(data, enabled: true)
        gateway.registry.decide(client, .readOnly, at: Date())
        _ = await bridge.call(overview)
        var connections = await gateway.connectionCount
        XCTAssertEqual(connections, 1)
        await gateway.setEnabled(true)
        connections = await gateway.connectionCount
        XCTAssertEqual(connections, 1, "Turning on twice keeps the running listener and its connections")
        await gateway.setEnabled(false)
        await gateway.setEnabled(false)
        let status = await gateway.status
        XCTAssertEqual(status, .off)
    }

    func testAPlaceThatCannotWorkKeepsTheGatewayOffAndSaysWhy() async throws {
        let root = try AgentTestDirectory.make(self)

        let long = gateway(root.appendingPathComponent(String(repeating: "x", count: 90), isDirectory: true))
        await long.setEnabled(true)
        var status = await long.status
        guard case .failed(.location(.pathTooLong)) = status else { return XCTFail("\(status)") }

        let loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose.appendingPathComponent("Agent"), withIntermediateDirectories: true)
        XCTAssertEqual(chmod(loose.appendingPathComponent("Agent").path, 0o755), 0)
        let unsafe = gateway(loose)
        await unsafe.setEnabled(true)
        status = await unsafe.status
        XCTAssertEqual(status, .failed(.location(.wrongPermissions(0o755))))

        let unverifiable = gateway(root.appendingPathComponent("plain", isDirectory: true), policy: { nil })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: false)
        await unverifiable.setEnabled(true)
        status = await unverifiable.status
        XCTAssertEqual(status, .failed(.bridgeUnverifiable), "Without a signed bridge to compare with, nothing listens")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSocketLocation.socketPath(
            dataDirectory: root.appendingPathComponent("plain"))))

        await unverifiable.setEnabled(false)
        status = await unverifiable.status
        XCTAssertEqual(status, .off, "Turning off clears the failure")
    }

    func testASecondGatewayDoesNotTakeOverALiveSocket() async throws {
        let data = try AgentTestDirectory.make(self)
        let first = gateway(data)
        await first.setEnabled(true)
        let second = gateway(data)
        await second.setEnabled(true)
        var status = await second.status
        XCTAssertEqual(status, .failed(.socket(EADDRINUSE)))
        status = await first.status
        XCTAssertEqual(status, .listening, "The running gateway keeps its socket")
        await second.setEnabled(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentSocketLocation.socketPath(dataDirectory: data)),
                      "Stopping the loser must not remove the winner's socket")
        await first.setEnabled(false)
    }

    func testTheAccessLogLivesBesideTheSocketAndCallsAreRecorded() async throws {
        let data = try AgentTestDirectory.make(self)
        let gateway = gateway(data)
        await gateway.setEnabled(true)
        _ = await transport(data, enabled: true).call(overview)
        let entries = await gateway.accessLog.entries()
        XCTAssertEqual(entries.map(\.reason), [.approvalRequired])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Agent/access.jsonl").path))
        await gateway.setEnabled(false)
        let kept = await gateway.accessLog.entries()
        XCTAssertEqual(kept.count, 1, "Records stay readable in Settings while the switch is off")
    }

    func testQuittingStopsAtOnceAndVoidsRequests() async throws {
        let data = try AgentTestDirectory.make(self)
        let gateway = gateway(data)
        await gateway.setEnabled(true)
        let waiting = try gateway.queue.add(.init(tool: "propose_empty_trash", module: "trash", summary: "s", reason: nil), from: client, at: Date())
        gateway.terminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSocketLocation.socketPath(dataDirectory: data)))
        XCTAssertEqual(try gateway.queue.request(waiting.id, for: client, at: Date()).state, .voided, "D267")
    }

    func testTurningOffVoidsRequests() async throws {
        let data = try AgentTestDirectory.make(self)
        let gateway = gateway(data)
        await gateway.setEnabled(true)
        let waiting = try gateway.queue.add(.init(tool: "propose_empty_trash", module: "trash", summary: "s", reason: nil), from: client, at: Date())
        await gateway.setEnabled(false)
        XCTAssertEqual(try gateway.queue.request(waiting.id, for: client, at: Date()).state, .voided, "D265")
    }

    func testPeerPolicyComesFromTheBundleOrNotAtAll() throws {
        let app = URL(fileURLWithPath: "/Applications/没有这个应用.app", isDirectory: true)
        let bridgePath = "/Applications/没有这个应用.app/Contents/Helpers/storage-cleaner-agent"
        let identities: [String: UpdateAskpassCodeIdentity] = [
            app.path: .init(identifier: "com.local.StorageCleanerMac.beta", team: "TEAM", cdhash: Data([1])),
            bridgePath: .init(identifier: "com.local.StorageCleanerMac.beta.agent-bridge", team: "TEAM", cdhash: Data([2]))
        ]
        let policy = try XCTUnwrap(AgentGatewayPolicy.bridgePolicy(applicationURL: app, identity: { identities[$0.path] }))
        XCTAssertEqual(policy.bridgeExecutable, bridgePath)
        XCTAssertEqual(policy.application.identifier, "com.local.StorageCleanerMac.beta")
        XCTAssertEqual(policy.bundledBridge.team, "TEAM")
        XCTAssertNil(AgentGatewayPolicy.bridgePolicy(applicationURL: app, identity: { $0 == app ? identities[app.path] : nil }),
                     "No readable bridge")
        XCTAssertNil(AgentGatewayPolicy.bridgePolicy(applicationURL: app, identity: { _ in nil }), "Unsigned App")
    }
}
