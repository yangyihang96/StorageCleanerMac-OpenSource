import FanControlShared
import Foundation
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

final class MacMiniModeCoordinatorTests: XCTestCase {
    @MainActor
    func testUninstalledHelperReadNeverRegistersOrSendsRequests() async {
        let coordinator = TestOperationFactory(for: self).fanControl(defaults: TestPreferenceDomain.make(for: self))
        await coordinator.refreshMacMiniMode()
        XCTAssertNil(coordinator.macMiniModeStatus)
        XCTAssertNil(coordinator.macMiniModeMessage)
        XCTAssertFalse(coordinator.isChangingMacMiniMode)
    }

    @MainActor
    func testUnapprovedHelperIsQuietUntilUserAttemptsEnable() async {
        let coordinator = makeCoordinator(handling: [], serviceStatus: { .requiresApproval }) { request in
            XCTFail("Unapproved helper must not receive \(request.operation)")
            return self.reply(request)
        }
        await coordinator.refreshMacMiniMode()
        XCTAssertNil(coordinator.macMiniModeMessage)
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertNotNil(coordinator.macMiniModeMessage)
        XCTAssertFalse(MacMiniModePresentation.isOn(coordinator.macMiniModeStatus))
    }

    @MainActor
    func testPeerConflictLeavesToggleOffAndShowsLocalizedReason() async {
        let observed = status(failure: .conflictingIdentity)
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode]) { request in
            if request.operation == .ping { return self.reply(request) }
            return FanControlHelperReply(operation: request.operation, success: false, message: "raw conflict",
                appliedTargetRPMByFan: [:], errorCode: .macMiniModeConflict, macMiniModeStatus: observed)
        }
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertEqual(coordinator.macMiniModeStatus?.mode, .off)
        XCTAssertEqual(coordinator.macMiniModeMessage, MacMiniModePresentation.failureMessage(.conflictingIdentity))
    }

    @MainActor
    func testRefreshOnlySendsReadRequestAndRetainsActualState() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let observed = status(mode: .whenOnAC, disabled: true, owned: true)
        let coordinator = makeCoordinator(handling: [.readMacMiniMode]) { request in
            operations.append(request.operation)
            return self.reply(request, status: observed)
        }
        await coordinator.refreshMacMiniMode()
        XCTAssertEqual(operations, [.readMacMiniMode])
        XCTAssertEqual(coordinator.macMiniModeStatus, observed)
        XCTAssertNil(coordinator.macMiniModeMessage)
    }

    @MainActor
    func testSetWaitsForTrustedHelperAndUsesVerifiedStatus() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let observed = status(mode: .whenOnAC, disabled: true, owned: true)
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode]) { request in
            operations.append(request.operation)
            return self.reply(request, status: request.operation == .setMacMiniMode ? observed : nil)
        }
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertEqual(operations.last, .setMacMiniMode)
        XCTAssertTrue(operations.dropLast().allSatisfy { $0 == .ping })
        XCTAssertEqual(coordinator.macMiniModeStatus, observed)
        XCTAssertFalse(coordinator.isChangingMacMiniMode)
    }

    @MainActor
    func testSetMissingReadbackNeverShowsConfirmedOn() async {
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode]) { request in self.reply(request) }
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertNil(coordinator.macMiniModeStatus)
        XCTAssertNotNil(coordinator.macMiniModeMessage)
        XCTAssertFalse(MacMiniModePresentation.isOn(coordinator.macMiniModeStatus))
    }

    @MainActor
    func testFailedVerificationKeepsTheReportedModeAndActualSleepValue() async {
        let failed = status(mode: .whenOnAC, disabled: false, owned: true, failure: .verificationFailed)
        let coordinator = makeCoordinator(handling: [.ping, .setMacMiniMode]) { request in
            if request.operation == .ping { return self.reply(request) }
            return FanControlHelperReply(operation: request.operation, success: false, message: "raw English error",
                appliedTargetRPMByFan: [:], errorCode: .macMiniModeVerificationFailed, macMiniModeStatus: failed)
        }
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertEqual(coordinator.macMiniModeStatus, failed)
        XCTAssertFalse(coordinator.macMiniModeStatus?.isConsistent ?? true)
        XCTAssertNotEqual(coordinator.macMiniModeMessage, "raw English error")
    }

    @MainActor
    func testOldHelperBlocksModeWriteAndOffersUpdate() async {
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = makeCoordinator(handling: [.ping]) { request in
            operations.append(request.operation)
            return FanControlHelperReply(protocolVersion: 2, operation: request.operation,
                success: true, message: "v2", appliedTargetRPMByFan: [:])
        }
        await coordinator.setMacMiniMode(.whenOnAC)
        XCTAssertEqual(operations, [.ping])
        XCTAssertTrue(coordinator.macMiniHelperNeedsUpdate)
        XCTAssertNil(coordinator.macMiniModeStatus)
    }

    @MainActor
    func testUnregisterRestoresSleepBeforeFansAndServiceRemoval() async {
        var operations: [String] = []
        var serviceStatus: SMAppService.Status = .enabled
        let coordinator = makeCoordinator(handling: [.setMacMiniMode, .restoreAutomatic],
            serviceStatus: { serviceStatus }, unregister: {
                operations.append("unregister")
                serviceStatus = .notRegistered
            }
        ) { request in
            operations.append(request.operation.rawValue)
            XCTAssertEqual(request.macMiniMode, request.operation == .setMacMiniMode ? .off : nil)
            return self.reply(request, status: request.operation == .setMacMiniMode ? self.status() : nil)
        }
        await coordinator.unregisterHelper()
        XCTAssertEqual(operations, ["setMacMiniMode", "restoreAutomatic", "unregister"])
        XCTAssertEqual(coordinator.helperStatus, .notRegistered)
    }

    @MainActor
    func testUnregisterStopsIfSleepRestorationIsUnconfirmed() async {
        var didUnregister = false
        let coordinator = makeCoordinator(handling: [.setMacMiniMode], unregister: { didUnregister = true }) { request in
            FanControlHelperReply(operation: request.operation, success: false, message: "unconfirmed",
                appliedTargetRPMByFan: [:], errorCode: .macMiniModeVerificationFailed,
                macMiniModeStatus: self.status(mode: .off, disabled: true, owned: true, failure: .verificationFailed))
        }
        await coordinator.unregisterHelper()
        XCTAssertFalse(didUnregister)
        XCTAssertEqual(coordinator.helperStatus, .enabled)
        XCTAssertNotNil(coordinator.lastMessage)
    }

    @MainActor
    func testVersion2RemovalUsesOnlyRestoreCompatibleRequest() async {
        var operations: [String] = []
        var serviceStatus: SMAppService.Status = .enabled
        let coordinator = makeCoordinator(handling: [.setMacMiniMode, .restoreAutomatic],
            serviceStatus: { serviceStatus }, unregister: {
                operations.append("unregister")
                serviceStatus = .notRegistered
            }
        ) { request in
            operations.append("\(request.operation.rawValue):\(request.protocolVersion)")
            if request.operation == .restoreAutomatic { XCTAssertTrue(request.isVersion2RestoreOnly) }
            return FanControlHelperReply(protocolVersion: 2, operation: request.operation,
                success: request.operation == .restoreAutomatic, message: "v2", appliedTargetRPMByFan: [:])
        }
        await coordinator.unregisterHelper()
        XCTAssertEqual(operations, ["setMacMiniMode:4", "restoreAutomatic:2", "unregister"])
    }

    @MainActor
    private func makeCoordinator(
        handling operations: Set<FanControlHelperRequest.Operation>,
        serviceStatus: @escaping () -> SMAppService.Status = { .enabled },
        unregister: @escaping () async throws -> Void = { throw CancellationError() },
        reply: @escaping @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply
    ) -> FanControlCoordinator {
        FanControlCoordinator(
            defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: operations, reply: reply),
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: serviceStatus, serviceRegistrar: { throw CancellationError() },
            serviceUnregistrar: unregister, approvalSettingsOpener: {}
        )
    }

    private func status(
        mode: MacMiniMode = .off, disabled: Bool = false, owned: Bool = false, failure: MacMiniModeFailure? = nil
    ) -> MacMiniModeStatus {
        MacMiniModeStatus(state: MacMiniPersistedState(mode: mode, ownsSleepDisabled: owned),
            readings: MacMiniSystemReadings(powerSource: .ac, sleepDisabled: disabled,
                                          clamshellClosed: false, clamshellCausesSleep: true), failure: failure)
    }

    private func reply(_ request: FanControlHelperRequest, status: MacMiniModeStatus? = nil) -> FanControlHelperReply {
        FanControlHelperReply(operation: request.operation, success: true, message: "fake",
                              appliedTargetRPMByFan: [:], macMiniModeStatus: status)
    }
}
