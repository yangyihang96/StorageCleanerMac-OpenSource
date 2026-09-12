import FanControlShared
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FanCurveCoordinatorTests: XCTestCase {
    func testApplyValidatesThenActivatesAndNeverSendsGenericRPMWrites() async {
        let suite = "FanCurveCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = CurveTestClock(Date(timeIntervalSince1970: 10_000))
        var requests: [FanControlHelperRequest] = []
        var activeProfileID: UUID?
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            now: { clock.now },
            requestSender: { request in
                requests.append(request)
                if let profile = request.curveProfile { activeProfileID = profile.id }
                let state: FanCurveRuntimeState? = switch request.operation {
                case .validateFanCurve:
                    .inactive
                case .activateFanCurve, .updateFanCurve,
                     .getFanCurveRuntimeState, .renewFanControlLease:
                    FanCurveRuntimeState(
                        status: .active,
                        rawTemperature: 53,
                        filteredTemperature: 52.5,
                        calculatedPercentage: 35,
                        appliedPercentage: 35,
                        targetRPMByFan: [0: 2_200],
                        actualRPMByFan: [0: 2_160],
                        activeProfileID: activeProfileID,
                        lastSensorUpdate: clock.now,
                        lastVerification: clock.now
                    )
                case .deactivateFanCurve, .restoreAutomatic:
                    .inactive
                default:
                    nil
                }
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "ok",
                    appliedTargetRPMByFan: state?.targetRPMByFan ?? [:],
                    curveRuntimeState: state
                )
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )
        coordinator.process(snapshot: snapshot(at: clock.now))

        await coordinator.applyFanCurveDraft()

        XCTAssertEqual(requests.map(\.operation), [.validateFanCurve, .activateFanCurve])
        XCTAssertEqual(coordinator.selectedMode, .customCurve)
        XCTAssertEqual(coordinator.observedMode, .customCurve)
        XCTAssertEqual(coordinator.curveRuntimeState.status, .active)
        XCTAssertNotNil(coordinator.curveStore.appliedProfile)
        XCTAssertFalse(requests.contains { $0.operation == .apply })

        let firstPoint = coordinator.curveStore.draftProfile.points[0]
        coordinator.curveStore.updatePoint(
            id: firstPoint.id,
            temperatureCelsius: firstPoint.temperatureCelsius + 2,
            speedFraction: firstPoint.speedFraction
        )
        XCTAssertEqual(requests.count, 2, "Editing a draft must not write SMC")

        clock.now = clock.now.addingTimeInterval(1)
        coordinator.process(snapshot: snapshot(at: clock.now))
        for _ in 0..<50 where requests.count < 3 { await Task.yield() }
        XCTAssertEqual(requests.last?.operation, .getFanCurveRuntimeState)
        XCTAssertFalse(requests.contains { $0.operation == .apply })
    }

    func testMissingSelectedSensorBlocksBeforeXPC() async {
        let suite = "FanCurveCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [FanControlHelperRequest] = []
        let now = Date()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            now: { now },
            requestSender: { request in
                requests.append(request)
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "unexpected",
                    appliedTargetRPMByFan: [:]
                )
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )
        coordinator.process(snapshot: snapshot(at: now))
        coordinator.curveStore.setSensor(.gpu)

        await coordinator.applyFanCurveDraft()

        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.curveStore.appliedProfile)
    }

    func testVerificationFailureReportsRestoreCompletionWithoutClaimingConfirmedMode() async {
        await assertVerificationFailureRecoveryFeedback(restoreSucceeds: true)
    }

    func testVerificationFailureDoesNotClaimRestoreAfterEveryRetryFails() async {
        await assertVerificationFailureRecoveryFeedback(restoreSucceeds: false)
    }

    private func assertVerificationFailureRecoveryFeedback(restoreSucceeds: Bool) async {
        let suite = "FanCurveCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        var operations: [FanControlHelperRequest.Operation] = []
        var pendingRestore: CheckedContinuation<Bool, Never>?
        var restoreCount = 0
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            now: { now },
            requestSender: { request in
                operations.append(request.operation)
                if request.operation == .validateFanCurve {
                    return FanControlHelperReply(
                        operation: request.operation,
                        success: true,
                        message: "valid",
                        appliedTargetRPMByFan: [:],
                        curveRuntimeState: .inactive
                    )
                }
                if request.operation == .activateFanCurve {
                    return FanControlHelperReply(
                        operation: request.operation,
                        success: false,
                        message: "readback failed",
                        appliedTargetRPMByFan: [:],
                        errorCode: .curveVerificationFailed
                    )
                }
                XCTAssertEqual(request.operation, .restoreAutomatic)
                restoreCount += 1
                let succeeded = if restoreCount == 1 {
                    await withCheckedContinuation { pendingRestore = $0 }
                } else {
                    restoreSucceeds
                }
                return FanControlHelperReply(
                    operation: request.operation,
                    success: succeeded,
                    message: succeeded ? "restore request completed" : "restore failed",
                    appliedTargetRPMByFan: [:]
                )
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )
        coordinator.process(snapshot: snapshot(at: now))

        await coordinator.applyFanCurveDraft()
        for _ in 0..<100 where pendingRestore == nil { await Task.yield() }

        let failureReason = L10n.text(
            "无法确认风扇目标转速已生效。",
            "The fan target could not be verified."
        )
        XCTAssertEqual(coordinator.lastMessage, failureReason + "\n" + L10n.text(
            "正在请求恢复系统自动控制，结果尚未确认。",
            "Requesting restoration of automatic system control; the result is unconfirmed."
        ))
        XCTAssertNil(coordinator.observedMode)
        guard let pendingRestore else {
            XCTFail("Expected a suspended restore request")
            return
        }
        pendingRestore.resume(returning: restoreSucceeds)

        let expectedStatus = restoreSucceeds ? L10n.text(
            "Helper 已确认恢复请求完成；当前硬件模式仍待确认。",
            "Helper confirmed completion of the restore request; the current hardware mode remains unconfirmed."
        ) : L10n.text(
            "恢复请求未获确认，请检查 Helper 连接与风扇状态。",
            "The restore request was not confirmed. Check the Helper connection and fan state."
        )
        let expectedMessage = failureReason + "\n" + expectedStatus
        for _ in 0..<200 where coordinator.lastMessage != expectedMessage {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertNil(coordinator.curveStore.appliedProfile)
        XCTAssertTrue(operations.contains(.restoreAutomatic))
        XCTAssertEqual(restoreCount, restoreSucceeds ? 1 : 3)
        XCTAssertEqual(coordinator.lastMessage, expectedMessage)
    }

    private func snapshot(at date: Date) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(
            generatedAt: date,
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanSpeedsRPM: [2_160],
            fanReadings: [
                SystemFanReading(
                    index: 0,
                    actualRPM: 2_160,
                    minimumRPM: 1_200,
                    maximumRPM: 6_400,
                    targetRPM: 2_200
                ),
            ],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 53),
            ],
            sensorAvailability: .available
        )
    }
}

@MainActor
private final class CurveTestClock {
    var now: Date

    init(_ now: Date) { self.now = now }
}
