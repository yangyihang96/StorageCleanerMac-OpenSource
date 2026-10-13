import FanControlShared
import Foundation
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

final class PowermetricsProtocolSafetyTests: XCTestCase {
    func testWireRequestHasExactlyAnOperationAndVersion() throws {
        let data = try FanControlHelperRequest.samplePowerMetrics.encodedForTransport()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["operation", "protocolVersion"])
        XCTAssertEqual(object["operation"] as? String, "samplePowerMetrics")
        XCTAssertEqual(try PowermetricsSamplingRequest.decode(data).protocolVersion, 4)
        for key in ["arguments", "executable", "samplers", "interval", "timeout", "macMiniMode", "targetRPMByFan"] {
            var forged = object
            forged[key] = "attacker"
            XCTAssertThrowsError(try PowermetricsSamplingRequest.decode(JSONSerialization.data(withJSONObject: forged)), key)
        }
        for version in [2, 3, 5] {
            XCTAssertThrowsError(try PowermetricsSamplingRequest.decode(JSONEncoder().encode(PowermetricsSamplingRequest(protocolVersion: version))))
        }
    }

    /// The reply is a fixed-shape DTO: numbers, a P/E cluster label and fixed
    /// failure codes. No raw plist, stderr, process name, path or free message.
    func testReplyDTOCarriesOnlyStructuredFields() throws {
        let sample = PowermetricsSample(cpuMilliwatts: 1, gpuMilliwatts: nil, aneMilliwatts: 0,
            clusters: [.init(name: "E0", kind: .efficiency, megahertz: 900)], gpuMegahertz: 400, durationSeconds: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["cpuMilliwatts", "gpuMilliwatts", "aneMilliwatts",
                                                     "clusters", "gpuMegahertz", "durationSeconds"]))
        let cluster = try XCTUnwrap((object["clusters"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(cluster.keys), ["name", "kind", "megahertz"])
        for name in ["E0; rm -rf /", "/usr/bin/powermetrics", "P", "P12345", "X0", "P0\u{0}"] {
            let forged = PowermetricsSample(cpuMilliwatts: 1, gpuMilliwatts: nil, aneMilliwatts: nil,
                clusters: [.init(name: name, kind: .performance, megahertz: 1)], gpuMegahertz: nil, durationSeconds: 1)
            XCTAssertFalse(forged.isValid, name)
        }
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PowermetricsResult.failure(.commandFailed))) as? [String: Any])
        XCTAssertEqual(Set(failure.keys), ["failure"])
        let forgedReply = FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "ok",
            appliedTargetRPMByFan: [:], powerSampleResult: .sample(PowermetricsSample(cpuMilliwatts: 1, gpuMilliwatts: nil,
                aneMilliwatts: nil, clusters: [.init(name: "ignored stderr text", kind: .performance, megahertz: 1)],
                gpuMegahertz: nil, durationSeconds: 1)))
        XCTAssertThrowsError(try forgedReply.validated(for: .samplePowerMetrics))
    }

    func testCallerPolicyRejectsWrongTeamIdentityAndRelocation() {
        let path = StorageCleanerBuildIdentity.installedApplicationPath
        let application = URL(fileURLWithPath: path)
        let executable = application.appendingPathComponent("Contents/MacOS/" + StorageCleanerBuildIdentity.appExecutableName)
        XCTAssertEqual(executable.path, StorageCleanerBuildIdentity.installedExecutablePath)
        let identifier = StorageCleanerBuildIdentity.appBundleIdentifier
        XCTAssertTrue(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
            executableURL: executable, helperApplicationURL: application))
        XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: identifier, team: "OTHER",
            executableURL: executable, helperApplicationURL: application))
        XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: "OTHER", team: "T9GZL52H8R",
            executableURL: executable, helperApplicationURL: application))
        for url in [URL(fileURLWithPath: "/tmp/Test.app/Contents/MacOS/StorageCleanerMac"),
                    application.appendingPathComponent("Contents/MacOS/Other"),
                    // The other build identity's executable name never matches.
                    application.appendingPathComponent("Contents/MacOS/" + (StorageCleanerBuildIdentity.isBeta
                        ? StorageCleanerBuildIdentity.releaseExecutableName : StorageCleanerBuildIdentity.betaExecutableName)),
                    application.appendingPathComponent("Contents/Resources/StorageCleanerMac")] {
            XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
                executableURL: url, helperApplicationURL: application))
        }
        XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
            executableURL: executable, helperApplicationURL: URL(fileURLWithPath: "/Moved.app")))
        XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
            executableURL: executable, helperApplicationURL: nil))
        // The helper derives its app URL with deletingLastPathComponent (trailing
        // slash); acceptance must not depend on a filesystem probe of the app.
        for helperApplication in [URL(fileURLWithPath: path, isDirectory: true), URL(fileURLWithPath: path, isDirectory: false),
                                  application.appendingPathComponent("Contents/Resources/Helper").deletingLastPathComponent()
                                      .deletingLastPathComponent().deletingLastPathComponent()] {
            XCTAssertTrue(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
                executableURL: URL(fileURLWithPath: executable.path, isDirectory: false),
                helperApplicationURL: helperApplication), helperApplication.absoluteString)
        }
        for escaped in [application.appendingPathComponent("../Evil.app/Contents/MacOS/StorageCleanerMac"),
                        URL(string: "https://example.invalid" + executable.path)!] {
            XCTAssertFalse(PowermetricsClientPolicy.permits(identifier: identifier, team: "T9GZL52H8R",
                executableURL: escaped, helperApplicationURL: application), escaped.absoluteString)
        }
    }

    func testSuccessRequiresValidStructuredSampleAndExactProtocolEcho() {
        let request = FanControlHelperRequest.samplePowerMetrics
        for reply in [
            FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "no data", appliedTargetRPMByFan: [:]),
            FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "failure", appliedTargetRPMByFan: [:], powerSampleResult: .failure(.timedOut)),
            FanControlHelperReply(protocolVersion: 3, operation: .samplePowerMetrics, success: true, message: "old", appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample)),
            FanControlHelperReply(operation: .ping, success: true, message: "wrong", appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample)),
            FanControlHelperReply(operation: .samplePowerMetrics, success: false, message: "contradictory", appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample)),
            FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "mixed control", appliedTargetRPMByFan: [0: 3_000], powerSampleResult: .sample(sample)),
            FanControlHelperReply(operation: .samplePowerMetrics, success: true, message: "mixed error", appliedTargetRPMByFan: [:], errorCode: .fanCrashRecoveryFailed, powerSampleResult: .sample(sample)),
        ] { XCTAssertThrowsError(try reply.validated(for: request)) }
        XCTAssertNoThrow(try FanControlHelperReply(operation: .samplePowerMetrics, success: true,
            message: "ok", appliedTargetRPMByFan: [:], powerSampleResult: .sample(sample)).validated(for: request))
    }

    @MainActor
    func testUnapprovedAndMissingHelpersNeverSendOrAuthorize() async {
        for serviceStatus in [SMAppService.Status.notRegistered, .requiresApproval, .notFound] {
            let coordinator = makeCoordinator(serviceStatus: { serviceStatus }) { _ in
                XCTFail("no XPC request before approval")
                return FanControlHelperReply(success: false, message: "unexpected", appliedTargetRPMByFan: [:])
            }
            let result = await coordinator.samplePowerMetrics()
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }

    @MainActor
    func testReadOnlyAppRequestReturnsDTOAndFlagsOldHelperForExistingUpdateFlow() async {
        let coordinator = makeCoordinator { request in
            XCTAssertEqual(request.operation, .samplePowerMetrics)
            return FanControlHelperReply(operation: request.operation, success: true, message: "ok",
                                         appliedTargetRPMByFan: [:], powerSampleResult: .sample(self.sample))
        }
        let result = await coordinator.samplePowerMetrics()
        XCTAssertEqual(result, .sample(sample))
        let old = makeCoordinator { request in
            FanControlHelperReply(protocolVersion: 3, operation: request.operation,
                                  success: false, message: "old", appliedTargetRPMByFan: [:])
        }
        let oldResult = await old.samplePowerMetrics()
        XCTAssertEqual(oldResult, .failure(.unavailable))
        XCTAssertTrue(old.macMiniHelperNeedsUpdate)
    }

    func testVersion3CompatibilityOnlyPermitsRemovalAndCannotSampleOrEnable() throws {
        let off = FanControlHelperRequest.disableMacMiniModeForVersion3
        let restore = FanControlHelperRequest.restoreAutomaticForVersion3
        XCTAssertTrue(off.isVersion3RemovalOnly)
        XCTAssertTrue(restore.isVersion3RemovalOnly)
        let status = MacMiniModeStatus(state: MacMiniPersistedState(), readings: MacMiniSystemReadings(
            powerSource: .ac, sleepDisabled: false, clamshellClosed: false, clamshellCausesSleep: true))
        XCTAssertNoThrow(try FanControlHelperReply(protocolVersion: 3, operation: .setMacMiniMode,
            success: true, message: "off", appliedTargetRPMByFan: [:], macMiniModeStatus: status).validated(for: off))
        for request in [FanControlHelperRequest.samplePowerMetrics, .setMacMiniMode(.whenOnAC), .restoreAutomatic] {
            XCTAssertThrowsError(try FanControlHelperReply(protocolVersion: 3, operation: request.operation,
                success: true, message: "old", appliedTargetRPMByFan: [:], macMiniModeStatus: status).validated(for: request))
        }
    }

    @MainActor
    func testVersion3RemovalVerifiesSleepOffBeforeRestoringFansAndUnregistering() async {
        var operations: [FanControlHelperRequest.Operation] = []
        var registered = true
        let status = MacMiniModeStatus(state: MacMiniPersistedState(), readings: MacMiniSystemReadings(
            powerSource: .ac, sleepDisabled: false, clamshellClosed: false, clamshellCausesSleep: true))
        let coordinator = makeCoordinator(serviceStatus: { registered ? .enabled : .notRegistered }, unregister: {
            XCTAssertEqual(operations, [.setMacMiniMode, .setMacMiniMode, .restoreAutomatic])
            registered = false
        }) { request in
            operations.append(request.operation)
            return FanControlHelperReply(protocolVersion: 3, operation: request.operation, success: true,
                message: "v3", appliedTargetRPMByFan: [:], macMiniModeStatus: request.operation == .setMacMiniMode ? status : nil)
        }
        await coordinator.unregisterHelper()
        XCTAssertFalse(registered)
    }

    @MainActor
    func testVersion3UnconfirmedSleepRecoveryBlocksUnregistration() async {
        var removed = false
        let status = MacMiniModeStatus(state: MacMiniPersistedState(ownsSleepDisabled: true), readings: MacMiniSystemReadings(
            powerSource: .ac, sleepDisabled: true, clamshellClosed: false, clamshellCausesSleep: true))
        let coordinator = makeCoordinator(unregister: { removed = true }) { request in
            FanControlHelperReply(protocolVersion: 3, operation: request.operation, success: true,
                message: "v3", appliedTargetRPMByFan: [:], macMiniModeStatus: status)
        }
        await coordinator.unregisterHelper()
        XCTAssertFalse(removed)
    }

    private var sample: PowermetricsSample {
        PowermetricsSample(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
            clusters: [], gpuMegahertz: nil, durationSeconds: 1)
    }
    @MainActor
    private func makeCoordinator(serviceStatus: @escaping () -> SMAppService.Status = { .enabled },
                                 unregister: @escaping () async throws -> Void = { XCTFail("must not unregister"); throw CancellationError() },
                                 reply: @escaping @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply) -> FanControlCoordinator {
        FanControlCoordinator(defaults: TestPreferenceDomain.make(for: self),
            helperStatusOverride: FanControlCoordinator.resolvedStatus(serviceStatus: serviceStatus(), legacyArtifactsPresent: false, legacyArtifactsCurrent: false),
            isHelperReachable: serviceStatus() == .enabled,
            requestSender: TestOperationFactory(for: self).fanRequestSender(
                handling: [.samplePowerMetrics, .setMacMiniMode, .restoreAutomatic], reply: reply), legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: serviceStatus,
            serviceRegistrar: { XCTFail("must not register"); throw CancellationError() },
            serviceUnregistrar: unregister, approvalSettingsOpener: { XCTFail("must not open authorization") })
    }
}
