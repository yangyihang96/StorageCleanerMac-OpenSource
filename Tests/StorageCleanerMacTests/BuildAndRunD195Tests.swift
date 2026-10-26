import XCTest
@testable import StorageCleanerMac

final class BuildAndRunD195Tests: XCTestCase {
    func testBetaInstallWaitsReadOnlyForBothIdleHelpersBeforeReplacingTheBundle() throws {
        let script = try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let install = try r2SourceDeclaration("install_beta() ", in: script)
        let quit = try XCTUnwrap(install.range(of: "quit_existing_beta_safely \"$target\"\n"))
        let replacement = try XCTUnwrap(install.range(of: "mv \"$target\" \"$backup\""))
        for label in ["FAN_HELPER_LABEL", "FILE_HELPER_LABEL"] {
            let wait = try XCTUnwrap(install.range(of:
                "python3 \"$ROOT_DIR/script/helper_upgrade_status.py\" wait-exit \"$\(label)\" 30 || true"))
            XCTAssertLessThan(quit.lowerBound, wait.lowerBound)
            XCTAssertLessThan(wait.lowerBound, replacement.lowerBound)
        }
        let commands = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        for forbidden in ["sudo ", "kickstart", "bootout"] { XCTAssertFalse(commands.contains(forbidden), forbidden) }
    }
}
