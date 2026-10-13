import FanControlShared
import Foundation
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FanControlStartupCoordinatorTests: XCTestCase {
    func testFaultReplyShowsChineseAndDoesNotRetryAutomaticFanRestore() async {
        let language = TestVolatilePreferences()
        defer { language.restore() }
        language.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.ping]) { request in
            operations.append(request.operation)
            return self.fault(request)
        }
        await coordinator.connectHelper()
        await coordinator.connectHelper()
        await coordinator.connectHelper()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(operations, [.ping], "No restore retry may reach the failed helper")
        XCTAssertEqual(coordinator.lastMessage, FanControlStartupSafety.failureMessageChinese)
        XCTAssertFalse(coordinator.isHelperReachable)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        await coordinator.prepareForTermination()
        XCTAssertEqual(operations, [.ping], "Shutdown cannot dispatch another fan write after startup failure")
        XCTAssertEqual(coordinator.lastMessage, FanControlStartupSafety.failureMessageChinese)
    }

    func testFailedHelperPreparationStopsAfterOneDiagnosticPing() async {
        var pings = 0
        let coordinator = makeCoordinator(handling: [.ping]) { request in
            pings += 1
            return self.fault(request)
        }
        await coordinator.registerHelper()
        XCTAssertEqual(pings, 1, "A typed startup failure must not be retried as a connection timeout")
        XCTAssertFalse(coordinator.isHelperReachable)
        XCTAssertEqual(coordinator.lastMessage, message)
    }

    func testCurveCannotActivateAfterStartupFaultAndSpecificReasonSurvives() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.ping]) { request in
            operations.append(request.operation)
            return self.fault(request)
        }
        await coordinator.registerHelper()
        await coordinator.applyFanCurveDraft()
        XCTAssertEqual(coordinator.lastMessage, message, "Startup failure also takes priority over missing telemetry")
        coordinator.process(snapshot: snapshot)
        for mode in [GeekFanControlMode.manual, .maximum, .customCurve, .systemAutomatic] {
            await coordinator.selectMode(mode)
            XCTAssertEqual(coordinator.lastMessage, message)
        }
        await coordinator.applyFanCurveDraft()
        XCTAssertEqual(operations, [.ping], "No validation, activation or manual write can reach XPC while fault is latched")
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.curveStore.appliedProfile)
        XCTAssertEqual(coordinator.lastMessage, message, "Keep the specific startup fault, not a generic curve error")
    }

    func testMacMiniAttemptReportsTheSameStartupFaultWithoutSendingEnable() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.readMacMiniMode, .ping]) { request in
            operations.append(request.operation)
            return self.fault(request)
        }
        await coordinator.refreshMacMiniMode()
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertEqual(operations.first, .readMacMiniMode)
        XCTAssertTrue(operations.dropFirst().allSatisfy { $0 == .ping })
        XCTAssertFalse(operations.contains(.setMacMiniMode))
        XCTAssertEqual(coordinator.macMiniModeMessage, message)
        XCTAssertEqual(coordinator.lastMessage, message)
        XCTAssertNil(coordinator.macMiniModeStatus)
        XCTAssertFalse(coordinator.isHelperReachable)
    }

    func testVerifiedReadyPingCanClearFaultInANewHealthyHelper() async {
        let healthy = HelperHealthFlag()
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.ping, .readMacMiniMode]) { request in
            operations.append(request.operation)
            if !healthy.value { return self.fault(request) }
            let status = request.operation == .readMacMiniMode
                ? MacMiniModeStatus(state: .init(), readings: .init(powerSource: .ac, sleepDisabled: false,
                    clamshellClosed: false, clamshellCausesSleep: true)) : nil
            return FanControlHelperReply(operation: request.operation, success: true, message: "ready",
                appliedTargetRPMByFan: [:], macMiniModeStatus: status)
        }
        await coordinator.registerHelper()
        XCTAssertFalse(coordinator.isHelperReachable)
        healthy.value = true
        await coordinator.registerHelper()
        XCTAssertTrue(coordinator.isHelperReachable)
        await coordinator.refreshMacMiniMode()
        XCTAssertEqual(operations, [.ping, .ping, .readMacMiniMode])
        XCTAssertNil(coordinator.macMiniModeMessage)
        XCTAssertEqual(coordinator.macMiniModeStatus?.mode, .off)
    }

    func testFaultLatchedUnregisterClearsSleepThenRemovesWithoutFanWrite() async {
        let enabled = HelperHealthFlag()
        enabled.value = true
        var events: [String] = []
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode], serviceEnabled: enabled, unregister: {
            events.append("unregister")
            enabled.value = false
        }) { request in
            events.append(request.operation.rawValue)
            if request.operation == .ping { return self.fault(request) }
            XCTAssertEqual(request.macMiniMode, .off)
            return self.sleepOffReply(request)
        }
        await coordinator.registerHelper()
        XCTAssertFalse(coordinator.offersHelperReconnect)
        await coordinator.unregisterHelper()
        XCTAssertEqual(events, ["ping", "setMacMiniMode", "unregister"])
        XCTAssertEqual(coordinator.helperStatus, .notRegistered)
        XCTAssertNil(coordinator.observedMode, "Removal cannot claim automatic fans were verified")
        XCTAssertTrue(coordinator.offersHelperConnectionAction, "A fresh authorization is now available")
        XCTAssertTrue(coordinator.lastMessage?.contains(L10n.text("仍未确认", "unconfirmed")) == true)
    }

    func testFaultSleepOffAndReadRemainUsableWithoutReadyPing() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode, .readMacMiniMode]) { request in
            operations.append(request.operation)
            return request.operation == .ping ? self.fault(request) : self.sleepOffReply(request)
        }
        await coordinator.registerHelper()
        await coordinator.setMacMiniMode(.off)
        await coordinator.refreshMacMiniMode()
        XCTAssertEqual(operations, [.ping, .setMacMiniMode, .readMacMiniMode])
        XCTAssertEqual(coordinator.macMiniModeStatus?.mode, .off)
        XCTAssertFalse(coordinator.macMiniModeStatus?.ownsSleepDisabled ?? true)
        XCTAssertFalse(coordinator.offersHelperReconnect, "Sleep recovery never clears a fan fault")
        XCTAssertEqual(coordinator.lastMessage, message)
    }

    func testFaultUnregisterStillRequiresConfirmedOwnSleepRecovery() async {
        var unregisters = 0
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode], unregister: { unregisters += 1 }) { request in
            if request.operation == .ping { return self.fault(request) }
            return FanControlHelperReply(operation: request.operation, success: false, message: "recovery failed",
                appliedTargetRPMByFan: [:], errorCode: .macMiniModeCommandFailed,
                macMiniModeStatus: .init(state: .init(ownsSleepDisabled: true),
                    readings: .init(powerSource: .ac, sleepDisabled: true, clamshellClosed: true, clamshellCausesSleep: true),
                    failure: .commandFailed))
        }
        await coordinator.registerHelper()
        await coordinator.unregisterHelper()
        XCTAssertEqual(unregisters, 0)
        XCTAssertTrue(coordinator.macMiniModeStatus?.ownsSleepDisabled == true)
        XCTAssertEqual(coordinator.lastMessage, MacMiniModePresentation.failureMessage(.commandFailed))
        XCTAssertFalse(coordinator.offersHelperReconnect)
    }

    func testFaultReconnectActionsAreHiddenAndAutomaticRefreshCannotPretendToReconnect() async {
        var pings = 0
        let coordinator = makeCoordinator(handling: [.ping]) { request in
            pings += 1
            return self.fault(request)
        }
        XCTAssertTrue(coordinator.offersHelperReconnect)
        await coordinator.registerHelper()
        XCTAssertFalse(coordinator.offersHelperReconnect)
        XCTAssertFalse(coordinator.offersHelperConnectionAction)
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 1)
        XCTAssertEqual(coordinator.lastMessage, message)
    }

    private func sleepOffReply(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        FanControlHelperReply(operation: request.operation, success: true, message: "sleep off confirmed",
            appliedTargetRPMByFan: [:], macMiniModeStatus: .init(state: .init(),
                readings: .init(powerSource: .ac, sleepDisabled: false, clamshellClosed: true, clamshellCausesSleep: true)))
    }

    private func makeCoordinator(
        handling operations: Set<FanControlHelperRequest.Operation>,
        serviceEnabled: HelperHealthFlag? = nil,
        unregister: @escaping @MainActor () async throws -> Void = { throw CancellationError() },
        reply: @escaping @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply
    ) -> FanControlCoordinator {
        FanControlCoordinator(defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled,
            isHelperReachable: true, now: { Date(timeIntervalSince1970: 10_000) },
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: operations, reply: reply),
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: { serviceEnabled?.value == false ? .notRegistered : .enabled },
            serviceRegistrar: { throw CancellationError() }, serviceUnregistrar: unregister, approvalSettingsOpener: { XCTFail("No live settings") })
    }

    private func fault(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        FanControlHelperReply(operation: request.operation, success: false, message: "raw helper failure",
            appliedTargetRPMByFan: [:], errorCode: .fanCrashRecoveryFailed)
    }

    private var message: String {
        L10n.text(FanControlStartupSafety.failureMessageChinese, FanControlStartupSafety.failureMessageEnglish)
    }

    private var snapshot: SystemMonitorSnapshot {
        SystemMonitorSnapshot(generatedAt: Date(timeIntervalSince1970: 10_000), metrics: [], networkThroughput: nil,
            thermalState: .nominal, fanSpeedsRPM: [2_160],
            fanReadings: [.init(index: 0, actualRPM: 2_160, minimumRPM: 1_200, maximumRPM: 6_400, targetRPM: 2_200)],
            temperatureReadings: [.init(zone: .chip, celsius: 53)], sensorAvailability: .available)
    }
}

private final class HelperHealthFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
