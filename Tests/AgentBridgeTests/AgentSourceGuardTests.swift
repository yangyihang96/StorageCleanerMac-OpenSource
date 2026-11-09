import Foundation
import XCTest

/// D260: the bridge only parses, forwards and answers. It has no network code,
/// starts no process, writes no file and never changes the App's settings.
/// The App-side gateway (AgentGatewayCore) may write its access log and socket.
final class AgentSourceGuardTests: XCTestCase {
    static let bridgeTargets = ["Sources/AgentShared", "Sources/AgentBridgeCore", "Sources/AgentBridge"]

    static let forbidden = [
        "URLSession", "import Network", "NWConnection", "NWListener", "CFSocket", "AF_INET", "getaddrinfo",
        "Process(", "NSTask", "posix_spawn", "execv", "fork(", "system(", "NSWorkspace",
        "createFile", ".write(to:", "createDirectory", "removeItem", "moveItem", "copyItem", "fopen(", "O_CREAT", "mkdir(",
        "unlink(", "rename(", "chmod(", "FileHandle(forWritingTo", "FileHandle(forUpdating",
        ".set(", "removeObject(forKey", "setValue(", "CFPreferencesSet", "CFBundleURLTypes"
    ]

    static func findings(in text: String, file: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap { index, line in
            forbidden.filter { line.contains($0) }.map { "\(file):\(index + 1): \($0)" }
        }
    }

    func testBridgeTargetsHoldNoNetworkProcessOrWriteCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        var findings: [String] = []
        for target in Self.bridgeTargets {
            let directory = root.appendingPathComponent(target)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
            for file in files {
                let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                findings += Self.findings(in: text, file: "\(target)/\(file)")
                scanned += 1
            }
        }
        XCTAssertGreaterThan(scanned, 10, "The scan must actually see the bridge sources")
        XCTAssertEqual(findings, [])
    }

    /// D267: the gateway stays resident while the switch is on, so it may not
    /// wake up on a timer. The askpass channel polls because it lives seconds.
    func testTheGatewayCoreHasNoPollingOrTimers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/AgentGatewayCore")
        var findings: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for pattern in ["poll(", "Timer.", "asyncAfter", "usleep(", "Thread.sleep", "Task.sleep"] where text.contains(pattern) {
                findings.append("\(file): \(pattern)")
            }
        }
        XCTAssertEqual(findings, [])
    }

    /// D260, D88: no URL scheme, so a web page cannot start anything. The build
    /// script names the key only to refuse a bundle that has it.
    func testTheBuildScriptRegistersNoURLScheme() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        XCTAssertFalse(script.contains("<key>CFBundleURLTypes</key>"))
        XCTAssertFalse(script.contains("plutil -insert CFBundleURLTypes"))
        XCTAssertTrue(script.contains("unexpected CFBundleURLTypes"))
    }

    func testTheGuardItselfCatchesEachPattern() {
        for pattern in Self.forbidden {
            // Some patterns overlap ("removeItem" also holds "moveItem"); each must be caught.
            XCTAssertTrue(Self.findings(in: "let x = 1\n  \(pattern)\n", file: "f").contains("f:2: \(pattern)"), pattern)
        }
        XCTAssertEqual(Self.findings(in: "let x = 1\n", file: "f"), [])
    }
}
