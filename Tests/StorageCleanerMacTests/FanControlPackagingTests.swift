import Foundation
import XCTest
@testable import StorageCleanerMac

final class FanControlPackagingTests: XCTestCase {
    func testFanControlUsesSMAppServiceAndAuthenticatedXPC() throws {
        let package = try source("Package.swift")
        let coordinator = try source(
            "Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"
        )
        let installer = try source(
            "Sources/StorageCleanerMac/Services/LegacyFanControlHelperInstaller.swift"
        )
        let helper = try source("Sources/FanControlHelper/main.swift")
        let curveController = try source("Sources/FanControlHelper/FanCurveController.swift")
        let battery = try source(
            "Sources/StorageCleanerMac/Services/BatteryHealthService.swift"
        )

        XCTAssertTrue(package.contains("StorageCleanerFanControlHelper"))
        XCTAssertTrue(coordinator.contains("SMAppService.daemon(plistName:"))
        XCTAssertTrue(coordinator.contains("try service.register()"))
        XCTAssertFalse(coordinator.contains("bundledArtifactsPresent()"))
        XCTAssertTrue(coordinator.contains("installedArtifactsMismatch"))
        XCTAssertTrue(coordinator.contains("NSXPCConnection("))
        XCTAssertTrue(coordinator.contains("bundledHelperSigningIsTrusted"))
        XCTAssertTrue(coordinator.contains("bundledHelperSigningTrustTask"))
        XCTAssertTrue(coordinator.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(coordinator.contains(
            "private static let bundledHelperSigningIsTrusted: Bool"
        ))
        XCTAssertTrue(coordinator.contains("bundledSigningContractIsTrusted("))
        XCTAssertTrue(coordinator.contains("untrustedBundledHelper"))
        XCTAssertTrue(coordinator.contains(
            "remoteObjectProxyWithErrorHandler { @Sendable error in"
        ))
        XCTAssertTrue(coordinator.contains(
            "helper.execute(requestData) { @Sendable replyData in"
        ))
        XCTAssertTrue(helper.contains("clientMatchesHelper(auditToken:"))
        XCTAssertTrue(helper.contains("clientIdentity.identifier == mainApplicationIdentifier"))
        XCTAssertTrue(helper.contains("watchdogDeadline"))
        XCTAssertTrue(helper.contains("restoreAllFans()"))
        XCTAssertTrue(helper.contains("exit(EXIT_SUCCESS)"))
        XCTAssertTrue(helper.contains("forcedFanIDs.subtracting(targetFanIDs)"))
        XCTAssertTrue(coordinator.contains("failClosed(reply.message)"))
        XCTAssertFalse(coordinator.contains("/usr/bin/sudo"))
        XCTAssertFalse(coordinator.contains("osascript"))
        XCTAssertFalse(installer.contains("with administrator privileges"))
        XCTAssertFalse(installer.contains("/usr/bin/osascript"))
        XCTAssertFalse(installer.contains("Process()"))
        XCTAssertTrue(installer.contains(
            "/Library/PrivilegedHelperTools/"
        ))
        XCTAssertTrue(installer.contains("installedArtifactsCurrent"))
        XCTAssertTrue(installer.contains("contentsEqual("))
        XCTAssertTrue(installer.contains("PropertyListSerialization.propertyList"))
        XCTAssertTrue(installer.contains("installedHelperPath"))
        XCTAssertFalse(installer.contains("/usr/bin/sudo"))
        XCTAssertTrue(coordinator.contains("func applyPowerMode("))
        XCTAssertTrue(helper.contains("case applyPowerMode"))
        XCTAssertTrue(helper.contains("case readPowerConfiguration"))
        XCTAssertTrue(helper.contains("case renewFanControlLease"))
        XCTAssertTrue(helper.contains("URL(fileURLWithPath: \"/usr/bin/pmset\")"))
        XCTAssertTrue(helper.contains("[\"-b\", \"-c\"].contains(source)"))
        XCTAssertTrue(helper.contains("runPMSet([\"-g\", \"custom\"])"))
        XCTAssertTrue(helper.contains("pmset readback did not match"))
        XCTAssertTrue(helper.contains("process.standardError = errorPipe"))
        XCTAssertTrue(helper.contains("process.environment = ["))
        XCTAssertTrue(helper.contains("verifiesManualTargets(forcedTargetRPMByFan)"))
        XCTAssertTrue(helper.contains("guard requestData.count <= 65_536"))
        XCTAssertTrue(curveController.contains("FanCurveValidator.validate("))
        XCTAssertTrue(helper.contains("FanCurveController"))
        XCTAssertTrue(helper.contains("curveTemperature(_ sensor: FanCurveSensor)"))
        XCTAssertFalse(helper.contains("writeSMC(key:"))
        XCTAssertFalse(helper.contains("setTemperatureKey"))
        XCTAssertFalse(helper.contains("executeCurveScript"))
        XCTAssertFalse(helper.contains("case manageStartupItem"))
        XCTAssertFalse(helper.contains("plistPath"))
        XCTAssertFalse(helper.contains("executablePath"))
        XCTAssertFalse(helper.contains("URL(fileURLWithPath: \"/bin/launchctl\")"))
        XCTAssertFalse(helper.contains("URL(fileURLWithPath: \"/bin/sh\")"))
        XCTAssertTrue(battery.contains(
            "powerModeWriter: any BatteryPowerModeCommandRunning = PrivilegedBatteryPowerModeCommandRunner()"
        ))
        XCTAssertFalse(battery.contains("with administrator privileges"))
        XCTAssertFalse(battery.contains("/usr/bin/osascript"))
    }

    func testAppleSiliconFanWritesRequireHardwareReadback() throws {
        let helper = try source("Sources/FanControlHelper/main.swift")

        XCTAssertTrue(helper.contains("let lowerCaseKey = \"F\\(fanID)md\""))
        XCTAssertTrue(helper.contains("read(lowerCaseKey) != nil"))
        XCTAssertFalse(helper.contains("read(\"F0md\") != nil"))
        XCTAssertTrue(helper.contains("case \"ui32\":"))
        XCTAssertTrue(helper.contains(
            "let dataSize = output.keyInfo.dataSize"
        ))
        XCTAssertTrue(helper.contains(
            "Array($0.prefix(Int(dataSize)))"
        ))
        XCTAssertTrue(helper.contains("usleep(3_000_000)"))
        XCTAssertTrue(helper.contains("for attempt in 0..<150"))
        XCTAssertTrue(helper.contains("targetMatches(fanID:"))
        XCTAssertTrue(helper.contains("firmware 0x%02x"))
        XCTAssertTrue(helper.contains(
            "requested \\(targetRPM) RPM, read back \\(observed) RPM"
        ))
        XCTAssertTrue(helper.contains(
            "let safeFloor = allowsRPMDecrease ? minimum : max(actual, minimum)"
        ))
        XCTAssertTrue(helper.contains(
            "let safeTarget = min(maximum, max(safeFloor, requestedRPM))"
        ))
        XCTAssertTrue(helper.contains(
            "Keep Ftst enabled until every fan has been returned"
        ))
    }

    func testFanTimeoutAndWatchdogQueuesRemainFailClosed() throws {
        let coordinator = try source(
            "Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"
        )
        let helper = try source("Sources/FanControlHelper/main.swift")

        XCTAssertTrue(coordinator.contains("case .apply, .activateFanCurve, .updateFanCurve:"))
        XCTAssertTrue(coordinator.contains(
            "completion.armTimeout(after: fanWriteRequestTimeout)"
        ))
        XCTAssertTrue(coordinator.contains("FanControlReplyCompletion(continuation)"))
        XCTAssertTrue(coordinator.contains("case timedOut"))
        XCTAssertTrue(helper.contains(
            "DispatchSource.makeTimerSource(queue: watchdogQueue)"
        ))
        XCTAssertTrue(helper.contains(
            "DispatchSource.makeTimerSource(queue: smcQueue)"
        ))
        XCTAssertTrue(helper.contains("startFanCurveTimer()"))
        XCTAssertTrue(helper.contains("FanCurveControlPolicy.standard.sampleInterval"))
        XCTAssertTrue(helper.contains("smcQueue.async { [weak self] in"))
        XCTAssertTrue(helper.contains("commandQueue"))
        XCTAssertTrue(helper.contains("case .apply, .renewFanControlLease, .restoreAutomatic,"))

        let armed = try XCTUnwrap(helper.range(of: "forcedFanIDs.formUnion(targetFanIDs)"))
        let firstTargetWrite = try XCTUnwrap(helper.range(
            of: "for (fanID, requestedRPM) in request.targetRPMByFan.sorted"
        ))
        XCTAssertLessThan(armed.lowerBound, firstTargetWrite.lowerBound)
    }

    func testLeaseFailureFeedbackDistinguishesCompletedAndUnconfirmedRestore() throws {
        let helper = try source("Sources/FanControlHelper/main.swift")
        let start = try XCTUnwrap(helper.range(of: "guard controller.verifiesManualTargets(forcedTargetRPMByFan) else"))
        let end = try XCTUnwrap(helper.range(of: "watchdogDeadline = Date().addingTimeInterval(request.watchdogSeconds)", range: start.upperBound..<helper.endIndex))
        let failureBranch = String(helper[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(failureBranch.contains("let restoreCompleted = restoreAllFans(using: controller)"))
        XCTAssertTrue(failureBranch.contains("restoreCompleted\n                    ?"))
        XCTAssertTrue(failureBranch.contains("the automatic-restore request completed."))
        XCTAssertTrue(failureBranch.contains("automatic restoration remains unconfirmed."))
        XCTAssertFalse(failureBranch.contains("automatic control was restored."))
        XCTAssertTrue(failureBranch.contains("errorCode: .fanVerificationFailed"))
    }

    func testHelperArmsCrashRecoveryBeforeWritesAndRecoversOnLaunch() throws {
        let helper = try source("Sources/FanControlHelper/main.swift")

        let marker = try XCTUnwrap(helper.range(
            of: "armCrashRecoveryMarker()"
        ))
        let firstTargetWrite = try XCTUnwrap(helper.range(
            of: "for (fanID, requestedRPM) in request.targetRPMByFan.sorted"
        ))
        XCTAssertLessThan(marker.lowerBound, firstTargetWrite.lowerBound)
        XCTAssertTrue(helper.contains(
            "guard recoverPreviousControlIfNeeded() else"
        ))
        XCTAssertTrue(helper.contains(
            "return restoreAllFans()"
        ))
        XCTAssertTrue(helper.contains(
            "clearCrashRecoveryMarker()"
        ))
        XCTAssertTrue(helper.contains(
            "exit(EXIT_FAILURE)"
        ))
    }

    func testFanCurveRunsInHelperAndKeepsEveryFailClosedBoundary() throws {
        let coordinator = try source(
            "Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"
        )
        let helper = try source("Sources/FanControlHelper/main.swift")
        let controller = try source("Sources/FanControlHelper/FanCurveController.swift")
        let editor = try source("Sources/StorageCleanerMac/Views/FanCurveEditor.swift")

        XCTAssertTrue(coordinator.contains("if selectedMode == .customCurve"))
        XCTAssertTrue(coordinator.contains("processCurveRuntime(at:"))
        XCTAssertTrue(coordinator.contains("NSWorkspace.willSleepNotification"))
        XCTAssertTrue(coordinator.contains("NSWorkspace.didWakeNotification"))
        XCTAssertTrue(coordinator.contains("await self.prepareForTermination()"))
        XCTAssertTrue(helper.contains("startFanCurveTimer()"))
        XCTAssertTrue(helper.contains("failCurveControl(.curveLeaseExpired)"))
        XCTAssertTrue(helper.contains("restoreAllFans()"))
        XCTAssertTrue(helper.contains("connections.removeAll"))
        XCTAssertTrue(controller.contains("ProcessInfo.processInfo.thermalState"))
        XCTAssertTrue(controller.contains("now < leaseDeadline"))
        XCTAssertTrue(controller.contains("recordSensorFailure(at:"))
        XCTAssertTrue(controller.contains("verifiesManualTargets"))
        XCTAssertTrue(controller.contains("curveFanRange(fanID:"))
        XCTAssertFalse(editor.contains("Timer."))
        XCTAssertFalse(editor.contains("DispatchSource"))
        XCTAssertFalse(editor.contains("applyCoolingBoost"))
    }

    func testLaunchDaemonPlistUsesBundleRelativeHelper() throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(
            "Resources/com.local.StorageCleanerMac.FanControlHelper.plist"
        ))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            plist["Label"] as? String,
            "com.local.StorageCleanerMac.FanControlHelper"
        )
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/Resources/StorageCleanerFanControlHelper"
        )
        let services = try XCTUnwrap(plist["MachServices"] as? [String: Bool])
        XCTAssertEqual(
            services["com.local.StorageCleanerMac.FanControlHelper"],
            true
        )
        XCTAssertNil(
            plist["AssociatedBundleIdentifiers"],
            "App-bundled daemons are associated automatically; this key is for legacy external jobs"
        )
        XCTAssertNil(
            plist["ProcessType"],
            "The bundled daemon should use the minimal SMAppService property list"
        )
    }

    func testBuildScriptsEmbedAndSignHelperBeforeOuterApplication() throws {
        for path in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            let script = try source(path)
            XCTAssertTrue(script.contains("Library/LaunchDaemons"))
            XCTAssertTrue(script.contains("StorageCleanerFanControlHelper"))
            XCTAssertTrue(script.contains("FAN_HELPER_PLIST"))
            XCTAssertFalse(script.contains("FAN_HELPER_LEGACY_PLIST"))
            XCTAssertFalse(script.contains(
                "ROOT_DIR/Resources/$FAN_HELPER_LABEL.legacy.plist"
            ))
        }

        let localBuild = try source("script/build_and_run.sh")
        XCTAssertFalse(localBuild.contains("--deep --sign"))
        XCTAssertTrue(localBuild.contains(
            "--preserve-metadata=entitlements"
        ))
        let localSparkleSign = try XCTUnwrap(
            localBuild.range(of: "sign_sparkle_framework \"$APP_FRAMEWORKS/Sparkle.framework\"")
        )
        let localHelperSign = try XCTUnwrap(
            localBuild.range(
                of: "--sign \"$SIGN_IDENTITY\" \"$APP_FAN_HELPER\"",
                range: localSparkleSign.upperBound..<localBuild.endIndex
            )
        )
        let localOuterSign = try XCTUnwrap(
            localBuild.range(
                of: "--sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\"",
                range: localHelperSign.upperBound..<localBuild.endIndex
            )
        )
        XCTAssertLessThan(localSparkleSign.lowerBound, localHelperSign.lowerBound)
        XCTAssertLessThan(localHelperSign.lowerBound, localOuterSign.lowerBound)

        let release = try source("script/make_release_dmg.sh")
        XCTAssertFalse(release.contains("--deep --sign"))
        XCTAssertTrue(release.contains("sign_sparkle_framework()"))
        XCTAssertTrue(release.contains("XPCServices/Installer.xpc"))
        XCTAssertTrue(release.contains("XPCServices/Downloader.xpc"))
        XCTAssertTrue(release.contains("--preserve-metadata=entitlements"))
        let helperSign = try XCTUnwrap(
            release.range(of: "sign_fan_helper \"$APP_FAN_HELPER\"")
        )
        let appSign = try XCTUnwrap(
            release.range(of: "sign_app_bundle \"$APP_BUNDLE\"")
        )
        XCTAssertLessThan(helperSign.lowerBound, appSign.lowerBound)
        XCTAssertTrue(release.contains(
            "sign_fan_helper \"$app_path/Contents/Resources/$FAN_HELPER_NAME\""
        ))
        let nestedSign = try XCTUnwrap(release.range(of:
            "sign_sparkle_framework \"$app_path/Contents/Frameworks/Sparkle.framework\""
        ))
        let helperInside = try XCTUnwrap(release.range(
            of: "sign_fan_helper \"$app_path/Contents/Resources/$FAN_HELPER_NAME\"",
            range: nestedSign.upperBound..<release.endIndex
        ))
        let outerInside = try XCTUnwrap(release.range(
            of: "codesign \"${sign_args[@]}\" --sign \"$SIGN_IDENTITY\" \"$app_path\"",
            range: helperInside.upperBound..<release.endIndex
        ))
        XCTAssertLessThan(nestedSign.lowerBound, helperInside.lowerBound)
        XCTAssertLessThan(helperInside.lowerBound, outerInside.lowerBound)
        XCTAssertTrue(release.contains(
            "codesign \"${sign_args[@]}\" --sign \"$SIGN_IDENTITY\" \"$app_path\""
        ))
        XCTAssertTrue(release.contains("Identifier=$FAN_HELPER_LABEL"))
        XCTAssertTrue(release.contains("codesign --verify --strict --verbose=4 \"$helper_path\""))
        XCTAssertTrue(release.contains("verify_fan_helper_signing_contract"))
        XCTAssertTrue(release.contains("app/helper signing team or certificate chain differs"))

        let notarize = try source("script/notarize_release.sh")
        XCTAssertTrue(notarize.contains("verify_fan_helper_distribution_contract"))
        XCTAssertTrue(notarize.contains("do not share the same signing team"))
        XCTAssertTrue(notarize.contains("do not share the same certificate chain"))
        XCTAssertTrue(notarize.contains("xcrun stapler validate \"$app_path\""))
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
