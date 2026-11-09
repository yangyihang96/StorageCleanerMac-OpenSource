import AgentGatewayCore
import Darwin
import FileOperationShared
import Foundation
import XCTest

/// D263: the App names the client from the bridge's process chain, skipping
/// shells and runtimes, and never from what the bridge or the client says.
final class AgentClientIdentityTests: XCTestCase {
    private let home = "/Users/fixture"

    private func identifier(_ table: [UpdateProcessSnapshot], signatures: [pid_t: UpdateAskpassCodeIdentity],
                            changing: pid_t? = nil) -> AgentClientIdentifier {
        let reads = AgentLookupCounter()
        let byPID = Dictionary(uniqueKeysWithValues: table.map { ($0.identity.pid, $0) })
        return AgentClientIdentifier(home: home, process: { pid in
            guard let snapshot = byPID[pid] else { return nil }
            guard pid == changing, reads.next() > 0 else { return snapshot }
            return UpdateProcessSnapshot(pid: pid, startTime: snapshot.identity.startTime + 1, parentPID: snapshot.parentPID,
                                         groupPID: snapshot.groupPID, uid: snapshot.uid, executable: snapshot.executable)
        }, signature: { signatures[$0] })
    }

    private func process(_ pid: pid_t, _ parent: pid_t, _ executable: String) -> UpdateProcessSnapshot {
        UpdateProcessSnapshot(pid: pid, startTime: UInt64(pid) * 10, parentPID: parent, groupPID: pid, uid: getuid(), executable: executable)
    }

    func testTerminalIsTheClientBehindShellAndLogin() throws {
        let table = [process(500, 400, "/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent"),
                     process(400, 300, "/bin/zsh"), process(300, 200, "/usr/bin/login"),
                     process(200, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")]
        let client = try XCTUnwrap(identifier(table, signatures: [
            400: .init(identifier: "com.apple.zsh", team: nil, cdhash: Data([1])),
            200: .init(identifier: "com.apple.Terminal", team: nil, cdhash: Data([2]))
        ]).identify(bridge: 500))
        XCTAssertEqual(client.displayName, "Terminal")
        XCTAssertEqual(client.kind, .signed)
        XCTAssertEqual(client.identifier, "com.apple.Terminal")
        XCTAssertEqual(client.bindingKey, "signed:com.apple.Terminal|")
    }

    func testCommandLineAgentBehindNodeIsNamedByItsOwnBinary() throws {
        let table = [process(510, 450, "/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent"),
                     process(450, 350, "/opt/homebrew/Cellar/node/24.1.0/bin/node"),
                     process(350, 340, "/Users/fixture/.local/share/claude/versions/3.0.1/claude"),
                     process(340, 1, "/bin/zsh")]
        let client = try XCTUnwrap(identifier(table, signatures: [
            450: .init(identifier: "node", team: nil, cdhash: Data([3]), adHoc: true),
            350: .init(identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW", cdhash: Data([4]))
        ]).identify(bridge: 510))
        XCTAssertEqual(client.displayName, "claude")
        XCTAssertEqual(client.executablePath, "~/.local/share/claude/versions/3.0.1/claude", "D266: the home folder is written as ~")
        XCTAssertEqual(client.bindingKey, "signed:com.anthropic.claude-code|Q6L2SF6YDW",
                       "Binds to the signer, so an update in a new folder keeps its approval")
    }

    func testHelperProcessesAreShownAsTheirApp() throws {
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let table = [process(520, 460, "/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent"),
                     process(460, 100, helper), process(100, 1, "/Applications/Claude.app/Contents/MacOS/Claude")]
        let client = try XCTUnwrap(identifier(table, signatures: [
            460: .init(identifier: "com.anthropic.claudefordesktop.helper", team: "Q6L2SF6YDW", cdhash: Data([5]))
        ]).identify(bridge: 520))
        XCTAssertEqual(client.displayName, "Claude")
        XCTAssertEqual(client.identifier, "com.anthropic.claudefordesktop.helper")
    }

    func testAdHocAndUnsignedClientsBindToBytesOrPath() throws {
        let adHoc = try XCTUnwrap(identifier([process(530, 470, "/b"), process(470, 1, "/Users/fixture/bin/runner")],
                                             signatures: [470: .init(identifier: "runner-55aa", team: nil, cdhash: Data([0xAB, 0x01]), adHoc: true)])
            .identify(bridge: 530))
        XCTAssertEqual(adHoc.kind, .adHoc)
        XCTAssertEqual(adHoc.bindingKey, "adhoc:runner-55aa|ab01", "A rebuilt ad-hoc client needs approval again")

        let unsigned = try XCTUnwrap(identifier([process(531, 471, "/b"), process(471, 1, "/Users/fixture/bin/runner")], signatures: [:])
            .identify(bridge: 531))
        XCTAssertEqual(unsigned.kind, .unsigned)
        XCTAssertEqual(unsigned.bindingKey, "path:~/bin/runner")
        XCTAssertEqual(unsigned.displayName, "runner")
    }

    func testNoClientWhenOnlyGenericProgramsOrTheChainChanges() {
        let generic = [process(540, 480, "/b"), process(480, 481, "/bin/sh"), process(481, 482, "/usr/bin/env"),
                       process(482, 483, "/opt/homebrew/bin/python3.13"), process(483, 1, "/opt/homebrew/bin/uv")]
        XCTAssertNil(identifier(generic, signatures: [:]).identify(bridge: 540), "Approving a shell would approve everything it runs")

        let replaced = [process(550, 490, "/b"), process(490, 1, "/Applications/Codex.app/Contents/MacOS/Codex")]
        XCTAssertNil(identifier(replaced, signatures: [490: .init(identifier: "com.openai.codex", team: "T", cdhash: Data([6]))],
                                changing: 490).identify(bridge: 550), "A PID reused while being read is not trusted")

        var deep = [process(600, 601, "/b")]
        for pid in 601..<640 { deep.append(process(pid_t(pid), pid_t(pid + 1), "/bin/bash")) }
        XCTAssertNil(identifier(deep, signatures: [:]).identify(bridge: 600))
        XCTAssertNil(identifier([], signatures: [:]).identify(bridge: 999))
    }

    func testGenericNamesAreBareNames() {
        // D98④ scans Sources line by line: a path ending in a shell's name fails the gate.
        for name in AgentClientIdentifier.genericProgramNames {
            XCTAssertFalse(name.contains("/"), name)
        }
        XCTAssertTrue(AgentClientIdentifier.isGeneric("python3.12"))
        XCTAssertTrue(AgentClientIdentifier.isGeneric("Node"))
        XCTAssertFalse(AgentClientIdentifier.isGeneric("codex"))
    }
}
