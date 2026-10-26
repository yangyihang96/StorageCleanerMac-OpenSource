import Foundation
import FanControlShared
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

final class FanControlProtocolSafetyTests: XCTestCase {
    func testCurrentProtocolRequiresExactOperationEcho() throws {
        for operation in [
            FanControlHelperRequest.Operation.ping,
            .readPowerConfiguration,
            .apply,
            .renewFanControlLease,
            .restoreAutomatic,
            .applyPowerMode,
            .validateFanCurve,
            .activateFanCurve,
            .updateFanCurve,
            .getFanCurveRuntimeState,
            .deactivateFanCurve,
        ] {
            let request = request(operation: operation)
            let curveState: FanCurveRuntimeState? = [
                .validateFanCurve, .activateFanCurve, .updateFanCurve,
                .getFanCurveRuntimeState,
            ].contains(operation) ? .inactive : nil
            let reply = FanControlHelperReply(
                operation: operation,
                success: true,
                message: "ok",
                appliedTargetRPMByFan: [:],
                curveRuntimeState: curveState
            )

            XCTAssertEqual(try reply.validated(for: request), reply)
            XCTAssertEqual(
                request.protocolVersion,
                FanControlHelperProtocolContract.currentVersion
            )
        }
    }

    func testPowerReadbackAndStructuredErrorRoundTripWithoutLosingOperation() throws {
        let configuration = FanControlPowerConfiguration(
            battery: .automatic,
            adapter: .highPower,
            supportedBatteryModes: [.automatic, .lowPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .lowPowerMode,
            adapterSetting: .powerMode
        )
        let reply = FanControlHelperReply(
            operation: .applyPowerMode,
            success: false,
            message: "readback mismatch",
            appliedTargetRPMByFan: [:],
            powerConfiguration: configuration,
            errorCode: .pmsetVerificationFailed
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                FanControlHelperReply.self,
                from: JSONEncoder().encode(reply)
            ),
            reply
        )
    }

    func testFanCurveRequestsUseTypedBoundedProfileAndLeaseDTOs() throws {
        let profile = FanCurveProfile.balanced(targetFanIDs: [0, 1])
        let leaseID = UUID()
        for request in [
            FanControlHelperRequest.validateFanCurve(profile),
            .activateFanCurve(profile, leaseID: leaseID),
            .updateFanCurve(profile, leaseID: leaseID),
            .renewFanCurveLease(leaseID),
            .getFanCurveRuntimeState,
            .deactivateFanCurve,
        ] {
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(FanControlHelperRequest.self, from: data)
            XCTAssertEqual(decoded.operation, request.operation)
            XCTAssertEqual(decoded.curveProfile, request.curveProfile)
            XCTAssertEqual(decoded.curveLeaseID, request.curveLeaseID)
            XCTAssertLessThan(data.count, 65_536)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("SMCKey"))
            XCTAssertFalse(text.contains("samplingInterval"))
            XCTAssertFalse(text.contains("executeCurveScript"))
        }
    }

    func testSuccessfulCurveReplyWithoutRuntimeStateIsRejected() {
        let profile = FanCurveProfile.balanced(targetFanIDs: [0])
        let request = FanControlHelperRequest.activateFanCurve(
            profile,
            leaseID: UUID()
        )
        let reply = FanControlHelperReply(
            operation: .activateFanCurve,
            success: true,
            message: "claimed success",
            appliedTargetRPMByFan: [0: 2_000]
        )

        XCTAssertThrowsError(try reply.validated(for: request)) { error in
            XCTAssertEqual(
                error as? FanControlHelperProtocolError,
                .missingCurveRuntimeState
            )
        }
    }

    func testLegacyAndWrongProtocolRepliesFailClosed() throws {
        let request = request(operation: .ping)
        let legacy = try JSONDecoder().decode(
            FanControlHelperReply.self,
            from: Data(
                #"{"success":true,"message":"old","appliedTargetRPMByFan":{}}"#.utf8
            )
        )

        XCTAssertThrowsError(try legacy.validated(for: request)) { error in
            XCTAssertEqual(
                error as? FanControlHelperProtocolError,
                .missingProtocolVersion
            )
        }

        let wrongVersion = FanControlHelperReply(
            protocolVersion: FanControlHelperProtocolContract.currentVersion + 1,
            operation: .ping,
            success: true,
            message: "wrong",
            appliedTargetRPMByFan: [:]
        )
        XCTAssertThrowsError(try wrongVersion.validated(for: request)) { error in
            XCTAssertEqual(
                error as? FanControlHelperProtocolError,
                .unsupportedProtocolVersion(
                    FanControlHelperProtocolContract.currentVersion + 1
                )
            )
        }

        let mismatched = FanControlHelperReply(
            operation: .apply,
            success: true,
            message: "wrong operation",
            appliedTargetRPMByFan: [:]
        )
        XCTAssertThrowsError(try mismatched.validated(for: request)) { error in
            XCTAssertEqual(
                error as? FanControlHelperProtocolError,
                .operationMismatch(expected: .ping, received: .apply)
            )
        }
    }

    func testUnavailableServiceMessageIsTruthfulAndReadOnly() {
        let message = FanControlHelperStatus.unavailableReadOnlyDetail

        XCTAssertFalse(message.contains("当前 App 副本未包含"))
        XCTAssertTrue(message.contains("Developer ID"))
        XCTAssertTrue(message.contains("公证") || message.contains("notarization"))
        XCTAssertTrue(message.contains("签名") || message.contains("signed"))
        XCTAssertTrue(
            message.contains("只读")
                || message.localizedCaseInsensitiveContains("read-only")
        )
    }

    func testLegacyMetadataRejectsSymlinkWrongOwnerAndWritableArtifacts() {
        let trusted = LegacyFanControlArtifactMetadata(
            isRegularFile: true,
            isSymbolicLink: false,
            ownerUserID: 0,
            posixPermissions: 0o755
        )
        XCTAssertTrue(trusted.isTrusted)
        XCTAssertFalse(LegacyFanControlArtifactMetadata(
            isRegularFile: true,
            isSymbolicLink: true,
            ownerUserID: 0,
            posixPermissions: 0o755
        ).isTrusted)
        XCTAssertFalse(LegacyFanControlArtifactMetadata(
            isRegularFile: true,
            isSymbolicLink: false,
            ownerUserID: 501,
            posixPermissions: 0o755
        ).isTrusted)
        XCTAssertFalse(LegacyFanControlArtifactMetadata(
            isRegularFile: true,
            isSymbolicLink: false,
            ownerUserID: 0,
            posixPermissions: 0o775
        ).isTrusted)
        XCTAssertFalse(LegacyFanControlArtifactMetadata(
            isRegularFile: true,
            isSymbolicLink: false,
            ownerUserID: 0,
            posixPermissions: 0o4755
        ).isTrusted)
    }

    @MainActor
    func testInjectedProtocolMismatchNeverBecomesReachableOrApplies() async {
        for response in [
            FanControlHelperReply(
                protocolVersion: FanControlHelperProtocolContract.currentVersion + 1,
                operation: .ping,
                success: true,
                message: "wrong version",
                appliedTargetRPMByFan: [:]
            ),
            FanControlHelperReply(
                operation: .apply,
                success: true,
                message: "wrong operation",
                appliedTargetRPMByFan: [:]
            ),
        ] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = TestPreferenceDomain.open(suiteName: suite)!
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            var operations: [FanControlHelperRequest.Operation] = []
            let coordinator = FanControlCoordinator(
                defaults: defaults,
                requestSender: { request in
                    operations.append(request.operation)
                    return response
                },
                legacyArtifactsPresentProvider: { false },
                legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled }
            )

            await coordinator.connectHelper()
            await coordinator.selectMode(.manual)

            XCTAssertFalse(coordinator.hasTrustedHelper)
            XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
            XCTAssertFalse(operations.contains(.apply))
        }
    }

    /// D102 L7: when the system ends the connection because the helper is not
    /// signed like this app, the message says so and the usual backed-off
    /// reconnect follows (an updated helper can match again). When this
    /// build's own signature gives no requirement, the message says that and
    /// nothing is retried.
    @MainActor
    func testSigningRequirementFailuresAreNamedAndOnlyAMismatchIsRetried() async throws {
        let mismatch = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionCodeSigningRequirementFailure)
        for (failure, first, retries) in [
            (mismatch as Error, L10n.text("辅助程序的签名与本应用不一致，已拒绝连接。",
                                          "The helper is not signed like this app, so the connection was refused."), true),
            (FanControlConnectionError.helperRequirementUnavailable as Error,
             L10n.text("未连接辅助程序，不会自动重试。", "Not connected to the helper; it will not retry automatically."), false),
        ] {
            var sleeps = 0
            let coordinator = FanControlCoordinator(
                defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled,
                requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.ping]) { _ in throw failure },
                reconnectSleeper: { _ in sleeps += 1; throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled })
            await coordinator.connectHelper()
            for _ in 0..<50 where sleeps == 0 { await Task.yield() }

            let message = try XCTUnwrap(coordinator.lastMessage)
            XCTAssertEqual(message.components(separatedBy: "\n").first, first, message)
            XCTAssertTrue(message.contains(failure.localizedDescription), message)
            XCTAssertEqual(sleeps > 0, retries, message)
            XCTAssertFalse(coordinator.hasTrustedHelper)
        }
        XCTAssertEqual(FanControlConnectionError.helperRequirementUnavailable.localizedDescription, L10n.text(
            "无法读取本应用的签名证书，未连接风扇控制辅助程序。",
            "This app's signing certificate could not be read, so it did not connect to the fan-control helper."))
    }

    @MainActor
    func testUnsafeLegacyArtifactsAreNeverMigratedOrUnregistered() async {
        for metadata in [
            LegacyFanControlArtifactMetadata(
                isRegularFile: true,
                isSymbolicLink: true,
                ownerUserID: 0,
                posixPermissions: 0o755
            ),
            LegacyFanControlArtifactMetadata(
                isRegularFile: true,
                isSymbolicLink: false,
                ownerUserID: 501,
                posixPermissions: 0o755
            ),
            LegacyFanControlArtifactMetadata(
                isRegularFile: true,
                isSymbolicLink: false,
                ownerUserID: 0,
                posixPermissions: 0o775
            ),
        ] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = TestPreferenceDomain.open(suiteName: suite)!
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            var events: [String] = []
            let coordinator = FanControlCoordinator(
                defaults: defaults,
                helperStatusOverride: .needsMigration,
                requestSender: TestOperationFactory(for: self).fanRequestSender(),
                legacyArtifactsPresentProvider: { true },
                legacyArtifactsCurrentProvider: { false },
                legacyArtifactsSafeForRemovalProvider: { metadata.isTrusted },
                legacyUninstaller: { events.append("uninstall") },
                serviceStatusProvider: { .notRegistered },
                serviceRegistrar: { events.append("register") }
            )

            await coordinator.migrateLegacyHelper()
            await coordinator.unregisterHelper()

            XCTAssertTrue(events.isEmpty)
            XCTAssertEqual(coordinator.helperStatus, .needsMigration)
            XCTAssertTrue(
                coordinator.lastMessage?.contains("旧版") == true
                    || coordinator.lastMessage?.contains("legacy") == true
            )
        }
    }

    func testLegacySigningRequiresExactIdentifiersTeamAndDeveloperIDChain() {
        let chain = ["Developer ID Application: Example (TEAM123)", "Developer ID Certification Authority"]
        let app = LegacyFanControlSigningIdentity(
            identifier: "com.local.StorageCleanerMac",
            teamIdentifier: "TEAM123",
            certificateCommonNames: chain
        )
        let helper = LegacyFanControlSigningIdentity(
            identifier: LegacyFanControlHelperInstaller.helperLabel,
            teamIdentifier: "TEAM123",
            certificateCommonNames: chain
        )

        XCTAssertTrue(LegacyFanControlHelperInstaller.signingContractIsTrusted(
            app: app,
            bundledHelper: helper,
            installedHelper: helper
        ))
        XCTAssertFalse(LegacyFanControlHelperInstaller.signingContractIsTrusted(
            app: app,
            bundledHelper: helper,
            installedHelper: LegacyFanControlSigningIdentity(
                identifier: helper.identifier,
                teamIdentifier: "OTHER",
                certificateCommonNames: chain
            )
        ))
        XCTAssertFalse(LegacyFanControlHelperInstaller.signingContractIsTrusted(
            app: LegacyFanControlSigningIdentity(
                identifier: app.identifier,
                teamIdentifier: app.teamIdentifier,
                certificateCommonNames: ["Apple Development: Example (TEAM123)"]
            ),
            bundledHelper: helper,
            installedHelper: helper
        ))

        let developmentChain = ["Apple Development: Example (TEAM123)"]
        let developmentApp = LegacyFanControlSigningIdentity(
            identifier: "com.local.StorageCleanerMac",
            teamIdentifier: "TEAM123",
            certificateCommonNames: developmentChain
        )
        let developmentHelper = LegacyFanControlSigningIdentity(
            identifier: LegacyFanControlHelperInstaller.helperLabel,
            teamIdentifier: "TEAM123",
            certificateCommonNames: developmentChain
        )
        XCTAssertTrue(
            LegacyFanControlHelperInstaller.bundledSigningContractIsTrusted(
                app: developmentApp,
                bundledHelper: developmentHelper
            )
        )
        XCTAssertFalse(
            LegacyFanControlHelperInstaller.bundledSigningContractIsTrusted(
                app: developmentApp,
                bundledHelper: LegacyFanControlSigningIdentity(
                    identifier: "com.local.WrongHelper",
                    teamIdentifier: "TEAM123",
                    certificateCommonNames: developmentChain
                )
            )
        )
    }

    private func request(
        operation: FanControlHelperRequest.Operation
    ) -> FanControlHelperRequest {
        FanControlHelperRequest(
            operation: operation,
            targetRPMByFan: [:],
            automaticFanIDs: [],
            allowsRPMDecrease: false,
            watchdogSeconds: 0,
            powerModeSource: nil,
            powerModeSetting: nil,
            powerModeValue: nil
        )
    }
}
