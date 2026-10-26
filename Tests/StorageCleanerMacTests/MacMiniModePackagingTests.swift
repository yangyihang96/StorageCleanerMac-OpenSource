import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacMiniModePackagingTests: XCTestCase {
    func testLaunchdLoadsAtBootAndOnlyRestartsNonzeroExits() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/com.local.StorageCleanerMac.FanControlHelper.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        let keepAlive = try XCTUnwrap(plist["KeepAlive"] as? [String: Bool])
        XCTAssertEqual(keepAlive, ["SuccessfulExit": false])
        XCTAssertNil(plist["StartInterval"])
        XCTAssertNil(plist["LaunchEvents"])
    }

    /// D102 L3: the Beta build writes its helper's launchd file from a heredoc;
    /// filled in with the Beta label it is the release file with only the label
    /// changed, so the Beta helper also starts at boot. Every build reads both
    /// keys back from the bundle.
    func testBetaHelperLaunchesLikeTheReleaseHelper() throws {
        let release = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/com.local.StorageCleanerMac.FanControlHelper.plist")),
            options: [], format: nil) as? [String: Any])
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let heredoc = try XCTUnwrap(script.range(of: "cat >\"$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST\" <<PLIST\n"))
        let end = try XCTUnwrap(script.range(of: "\nPLIST\n", range: heredoc.upperBound..<script.endIndex))
        let label = "com.local.StorageCleanerMac.beta.FanControlHelper"
        let text = script[heredoc.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "$FAN_HELPER_LABEL", with: label)
            .replacingOccurrences(of: "$FAN_HELPER_NAME", with: "StorageCleanerFanControlHelper")
        XCTAssertFalse(text.contains("$"), text)
        var beta = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
            as? [String: Any])
        XCTAssertEqual(beta["Label"] as? String, label)
        XCTAssertEqual(beta["MachServices"] as? [String: Bool], [label: true])
        beta["Label"] = release["Label"]
        beta["MachServices"] = release["MachServices"]
        XCTAssertEqual(NSDictionary(dictionary: beta), NSDictionary(dictionary: release))

        let check = try r2SourceDeclaration("verify_sparkle_bundle()", in: script)
        let file = "\"$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST\")\""
        XCTAssertTrue(check.contains("[ \"$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' " + file + " = \"true\" ]"))
        XCTAssertTrue(check.contains("[ \"$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' " + file + " = \"false\" ]"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "\nverify_sparkle_bundle\n", in: script), 1)
    }

    // Wiring checks only. Lifecycle behavior is exercised by the shared
    // policy/engine tests, including connected idle, termination and removal.
    func testHelperLifecycleAndCommandBoundaryUseSharedPolicy() throws {
        let helper = try source("Sources/FanControlHelper/main.swift")
        let runtime = try source("Sources/FanControlHelper/MacMiniModeRuntime.swift")
        XCTAssertTrue(helper.contains("guard HelperPMSetWhitelist.permits(arguments) else"))
        XCTAssertTrue(helper.contains("HardwareControlProtocol.accepts(protocolVersion)"))
        XCTAssertTrue(helper.contains("MacMiniHelperIdlePolicy.mayExit("))
        XCTAssertTrue(helper.contains("connectionCount: self.connections.count"))
        XCTAssertTrue(helper.contains("[SIGTERM, SIGINT]"))
        XCTAssertTrue(helper.contains("macMiniRuntime?.prepareForTermination()"))
        XCTAssertTrue(runtime.contains("lifecycle.reconcile()"))
        XCTAssertTrue(runtime.contains("lifecycle.prepareForTermination()"))
        XCTAssertTrue(runtime.contains("MacMiniPolicyStore.openOrDegrade("))
        XCTAssertTrue(runtime.contains("MacMiniPolicyStore.readRecoveryWithoutLock("))
        XCTAssertTrue(runtime.contains("StorageCleanerMac-MacMiniMode-Lock (root 0700)"))
        XCTAssertTrue(runtime.contains("Bundle.main.executableURL"))
        XCTAssertFalse(runtime.contains("CommandLine.arguments"))
        XCTAssertTrue(runtime.contains("repeating: 60"))
        XCTAssertTrue(runtime.contains("IOPSNotificationCreateRunLoopSource"))
        XCTAssertTrue(runtime.contains("[.delete, .rename, .revoke]"))
        XCTAssertFalse(runtime.contains("IORegistryEntrySetCFProperty"))
    }

    func testPolicyStoreIsRootOnlyAndRejectsLinks() throws {
        let runtime = try source("Sources/FanControlHelper/MacMiniModeRuntime.swift")
        let store = try source("Sources/FanControlShared/MacMiniPolicyStore.swift")
        XCTAssertTrue(runtime.contains("trustedOwner: 0"))
        XCTAssertTrue(runtime.contains("/private/var/db/"))
        XCTAssertTrue(store.contains("O_NOFOLLOW"))
        XCTAssertTrue(store.contains("metadata.st_uid == owner"))
        XCTAssertTrue(store.contains("metadata.st_nlink == 1"))
        XCTAssertTrue(store.contains("0o700"))
        XCTAssertTrue(store.contains("0o600"))
        XCTAssertTrue(store.contains("try file.synchronize()"))
        XCTAssertTrue(store.contains("fsync(directory) == 0"))
        XCTAssertTrue(store.contains("record.application == application"))
        XCTAssertFalse(store.contains("applicationDevice"))
        XCTAssertFalse(store.contains("applicationInode"))
    }

    func testPaletteControlIsMinimalVisibleOnlyAndFixtureSafe() throws {
        let control = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MacMiniModeControls.swift")
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        let page = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")
        XCTAssertTrue(palette.contains("MacMiniModeControls(fanControl: fanControl, hasInternalBattery: hasInternalBattery)"))
        XCTAssertTrue(page.contains("else { geekMacMiniModeCard }"))
        XCTAssertTrue(page.contains("MacMiniHardwareCapabilities.shouldOffer("))
        XCTAssertTrue(control.contains("MacMiniHardwareCapabilities.shouldOffer("))
        XCTAssertTrue(control.contains("mac-mini-mode-toggle"))
        XCTAssertTrue(control.contains("fanControl.setMacMiniMode(enabled ? .whenOnAC : .off)"))
        XCTAssertTrue(control.contains("guard !fanControl.isDataOnlyFixture else { return }"))
        XCTAssertTrue(control.contains("MacMiniModePresentation.safetyNotice"))
        XCTAssertTrue(control.contains("MacMiniModePresentation.reason"))
        XCTAssertTrue(control.contains("while !Task.isCancelled, MacMiniModePresentation.isOn"))
        XCTAssertFalse(control.contains("systemImage:"))
        XCTAssertFalse(control.contains("AppSymbolGlyph"))
        XCTAssertFalse(control.contains("FanControlCoordinator.shared"))
    }

    func testFourthRoundRecoveryCachingAndDeferredBootstrapAreWired() throws {
        let helper = try source("Sources/FanControlHelper/main.swift")
        let runtime = try source("Sources/FanControlHelper/MacMiniModeRuntime.swift")
        let coordinator = try source("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift")
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        let sensors = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        XCTAssertTrue(helper.contains("FanControlStartupSafety.permitsSleepRecovery("))
        XCTAssertTrue(helper.contains("startupSafety.dispatchSleepRecovery(recover:"))
        XCTAssertTrue(helper.contains("macMiniRuntime.disableForRemoval()"))
        XCTAssertTrue(runtime.contains("lifecycle.disableForRemoval()"))
        XCTAssertTrue(runtime.contains("MacMiniDeferredBootstrap<BootstrapValue>"))
        XCTAssertTrue(runtime.contains("validateApplication: { installation.validatePeer($0) }"))
        XCTAssertTrue(runtime.contains("metadata: MacMiniApplicationValidation.readMetadata"))
        XCTAssertTrue(runtime.contains("self.installation.invalidate()"))
        XCTAssertTrue(coordinator.contains("!request.isMacMiniSleepRecoveryRequest"))
        XCTAssertTrue(palette.contains("offersAction: fanControl.offersHelperConnectionAction"))
        XCTAssertTrue(sensors.contains("fanControl.offersHelperConnectionAction"))
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try r2ProductionSource(at: root.appendingPathComponent(path))
    }
}
