import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class BetaDistributionTests: XCTestCase {
    func testBuildIdentitiesKeepProductionAndBetaNamespacesSeparate() {
        XCTAssertEqual(
            AppDataDirectories.applicationSupportDirectoryName(isBeta: false),
            "StorageCleanerMac"
        )
        XCTAssertEqual(
            AppDataDirectories.applicationSupportDirectoryName(isBeta: true),
            "StorageCleanerMac-Beta"
        )
        XCTAssertEqual(StorageCleanerBuildIdentity.appBundleIdentifier, "com.local.StorageCleanerMac")
        XCTAssertEqual(
            StorageCleanerBuildIdentity.helperLabel,
            "com.local.StorageCleanerMac.FanControlHelper"
        )
    }

    func testBuildInfoRejectsIncompleteMetadataAndMarksDirtyCommit() throws {
        XCTAssertNil(AppBuildInfo.decode(["version": "1.9.10"]))

        let info = try XCTUnwrap(AppBuildInfo.decode([
            "version": "1.9.10",
            "build": "20260810120000",
            "commit": "78c6d3520e59",
            "dirty": true,
            "buildDate": "2026-08-10T02:00:00Z",
            "configuration": "Beta",
        ]))

        XCTAssertTrue(info.isBeta)
        XCTAssertEqual(info.commitDisplay, "78c6d3520e59-dirty")
        let copied = info.betaDiagnosticsMarkdown(
            helperStatus: "尚未启用",
            advancedControlStatus: "尚未注册"
        )
        XCTAssertTrue(copied.contains("存储清理助手 1.9.10"))
        XCTAssertTrue(copied.contains("Build 20260810120000"))
        XCTAssertTrue(copied.contains("Commit 78c6d3520e59-dirty"))
        XCTAssertFalse(copied.contains(NSHomeDirectory()))
        XCTAssertFalse(copied.localizedCaseInsensitiveContains("serial"))
    }

    func testUnifiedRunScriptOwnsStableSignedBetaInstallFlow() throws {
        let script = try source("script/build_and_run.sh")
        let updater = try source("Sources/StorageCleanerMac/Services/AppUpdater.swift")
        let screenshotCapture = try source("script/capture_app_windows.swift")
        let hardwareControl = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"
        )

        for required in [
            "com.local.StorageCleanerMac.beta",
            "com.local.StorageCleanerMac.beta.FanControlHelper",
            "STORAGE_CLEANER_BETA",
            "/Applications/测试版.app",
            "BuildInfo.plist",
            "quit_existing_beta_safely",
            "测试版.previous.app",
            "StorageCleanerBetaBuild",
            "*.lproj/InfoPlist.strings",
            "capture_app_windows.swift",
            "beta_overview_card_accessibility",
        ] {
            XCTAssertTrue(script.contains(required), "missing Beta contract: \(required)")
        }
        XCTAssertTrue(updater.contains("startingUpdater: true"))
        XCTAssertFalse(updater.contains("guard !StorageCleanerBuildIdentity.isBeta"))
        XCTAssertTrue(script.contains("StorageCleanerMacUpdates/main/appcast-beta.xml"))
        XCTAssertTrue(hardwareControl.contains(
            "if telemetry.hasVerifiedRanges {"
        ))
        XCTAssertTrue(hardwareControl.contains(
            "Button { presentation.showFanCurveEditor() } label: {"
        ))
        XCTAssertTrue(hardwareControl.contains("Text(L10n.text(\"编辑曲线\", \"Edit Curve\"))"))
        XCTAssertFalse(script.contains("sudo "))
        XCTAssertFalse(script.contains("with administrator privileges"))
        XCTAssertTrue(screenshotCapture.contains("SCContentFilter(display: display, including: windows)"))
        XCTAssertTrue(screenshotCapture.contains("window.owningApplication?.processID == processID"))
    }

    /// The install check compares the running process path, which contains
    /// "测试版". Outside a UTF-8 locale `ps` escapes those bytes, so a shell
    /// without LANG judged a correct install as failed and rolled it back
    /// (2026-10-04). The check must read the path through the pinned helper.
    func testInstallPathCheckReadsNonASCIIProcessPathsInAnyLocale() throws {
        let script = try source("script/build_and_run.sh")
        XCTAssertTrue(script.contains("command=\"$(process_command \"$pid\")\""))
        XCTAssertFalse(script.contains("command=\"$(ps -p"))
        let start = try XCTUnwrap(script.range(of: "process_command() {"))
        let end = try XCTUnwrap(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let helper = String(script[start.lowerBound..<end.upperBound])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("测试版-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("测试版进程")
        try FileManager.default.createSymbolicLink(
            at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let sleeper = Process()
        sleeper.executableURL = executable
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }

        // The same shell conditions as the failed install: no UTF-8 locale.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", "\(helper)\nprocess_command \(sleeper.processIdentifier)"]
        shell.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        shell.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(command.hasPrefix(executable.path), "ps reported: \(command)")
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
