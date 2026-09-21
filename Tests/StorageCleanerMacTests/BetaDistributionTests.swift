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
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHardwareControlView.swift"
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
            "if telemetry.telemetryAvailable, telemetry.fanCount > 0"
        ))
        XCTAssertTrue(hardwareControl.contains(
            "Button(L10n.text(\"编辑曲线\", \"Edit Curve\"), action: editCurve)"
        ))
        XCTAssertFalse(script.contains("sudo "))
        XCTAssertFalse(script.contains("with administrator privileges"))
        XCTAssertTrue(screenshotCapture.contains("SCContentFilter(display: display, including: windows)"))
        XCTAssertTrue(screenshotCapture.contains("window.owningApplication?.processID == processID"))
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
