import XCTest
@testable import StorageCleanerMac

@MainActor
final class HardwareControlPresentationTests: XCTestCase {
    func testFanPercentageUsesOnlyCompleteVerifiedRanges() {
        let verified = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 1_620, minimum: 1_200, maximum: 4_000),
        ]))
        XCTAssertEqual(verified.percentage ?? -1, 15, accuracy: 0.001)
        XCTAssertTrue(verified.hasVerifiedRanges)

        let readOnly = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 1_620, minimum: nil, maximum: nil),
        ]))
        XCTAssertNil(readOnly.percentage)
        XCTAssertEqual(readOnly.actualRPM, 1_620)
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: readOnly, helperState: .enabled),
            .readOnly
        )

        let partiallyVerified = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(index: 0, actual: 1_620, minimum: 1_200, maximum: 4_000),
            fan(index: 1, actual: 1_800, minimum: nil, maximum: nil),
        ]))
        XCTAssertNil(partiallyVerified.percentage)
        XCTAssertFalse(partiallyVerified.hasVerifiedRanges)
    }

    func testTelemetryDistinguishesSamplingFanlessAndRawRPM() {
        let sampling = FanTelemetryState.resolve(snapshot: snapshot(
            readings: nil,
            availability: .sampling
        ))
        XCTAssertTrue(sampling.isSampling)
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: sampling, helperState: .enabled),
            .checking
        )

        let fanless = FanTelemetryState.resolve(snapshot: snapshot(
            readings: nil,
            fanCount: 0,
            availability: .available
        ))
        XCTAssertTrue(fanless.isFanless)
        guard case .unsupported = FanControlCapability.resolve(
            telemetry: fanless,
            helperState: .enabled
        ) else {
            return XCTFail("Fanless hardware must be presented as unsupported, not 0%")
        }

        let raw = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            metrics: [],
            networkThroughput: nil,
            fanSpeedsRPM: [1_620],
            sensorAvailability: .available
        ))
        XCTAssertEqual(raw.actualRPM, 1_620)
        XCTAssertNil(raw.percentage)
    }

    func testFanAvailabilityDoesNotFollowOtherSensors() {
        for availability in [SystemSensorAvailability.available, .sampling] {
            let failed = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
                generatedAt: Date(timeIntervalSince1970: 1),
                metrics: [],
                networkThroughput: nil,
                sensorAvailability: availability,
                fanAvailability: .unavailable
            ))
            XCTAssertFalse(failed.isFanless)
            XCTAssertFalse(failed.isSampling)
            XCTAssertFalse(failed.telemetryAvailable)
            XCTAssertNil(failed.actualRPM)
        }

        let firstFanSample = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            metrics: [],
            networkThroughput: nil,
            sensorAvailability: .available,
            fanAvailability: .sampling
        ))
        XCTAssertTrue(firstFanSample.isSampling)
        XCTAssertFalse(firstFanSample.isFanless)

        let stopped = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 0, minimum: 1_200, maximum: 4_000),
        ]))
        XCTAssertEqual(stopped.actualRPM, 0)
        XCTAssertTrue(stopped.telemetryAvailable)
        XCTAssertFalse(stopped.isSampling)
        XCTAssertFalse(stopped.isFanless)
    }

    /// A relaunched app starts with `isHelperReachable == false`, so an
    /// approved helper reads "connection interrupted" until something pings
    /// it. Reconnect on opening, while registration stays an explicit Helper
    /// action and curve drafting remains available without write access.
    func testFanPaletteSelfHealsAfterRelaunchInsteadOfDeadDisabling() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let palette = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(palette.contains(".task(id: presentation.kind)"))
        XCTAssertTrue(palette.contains("await fanControl.refreshConnection()"))

        let gate = try XCTUnwrap(palette.range(of: "private var applyDisabledReason").map {
            String(palette[$0.lowerBound...].prefix(2_200))
        })
        XCTAssertTrue(gate.contains("if fanControl.helperState != .enabled"), "Unconnected hardware must not appear writable")
        XCTAssertTrue(gate.contains("if fanControl.isDataOnlyFixture"))
        XCTAssertTrue(palette.contains("draft.selectMode(mode)"), "Mode selection previews a draft without submitting")
        XCTAssertTrue(palette.contains("enable: { Task { await fanControl.registerHelper() } }"))
        XCTAssertTrue(palette.contains("fan-control-layout-toggle"))
        XCTAssertFalse(palette.contains("if showsExpandedControls, fanControl.helperState == .enabled"))
        let rpmPosition = try XCTUnwrap(palette.range(of: "                fanReadbackRows")).lowerBound
        let helperGate = try XCTUnwrap(palette.range(of: "                    if fanControl.helperState != .enabled", range: rpmPosition..<palette.endIndex)).lowerBound
        XCTAssertLessThan(rpmPosition, helperGate, "Read-only RPM remains above the Helper-only action")
    }

    func testConnectedHelperDoesNotTurnReadOnlyTelemetryOrUnknownModeIntoControl() {
        let telemetry = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 0, minimum: nil, maximum: nil),
        ]))
        let capability = FanControlCapability.resolve(telemetry: telemetry, helperState: .enabled)
        XCTAssertEqual(capability, .readOnly)
        XCTAssertEqual(FanStatusPresentation.controlTitle(capability), L10n.text("只读", "Read Only"))
        XCTAssertEqual(FanStatusPresentation.connectionTitle(.enabled), L10n.text("已连接", "Connected"))
        XCTAssertEqual(FanStatusPresentation.approvalTitle(.enabled), L10n.text("已批准", "Approved"))
        XCTAssertEqual(FanStatusPresentation.confirmedModeTitle(nil), "—")
        XCTAssertEqual(FanStatusPresentation.confirmedModeTitle(.manual), FanControlMode.manual.title)
        XCTAssertEqual(FanStatusPresentation.controlTitle(.controllable), L10n.text("可提交控制", "Ready to Submit"))
        XCTAssertEqual(FanStatusPresentation.approvalTitle(.requiresApproval), L10n.text("等待批准", "Awaiting Approval"))
    }

    /// Two GUI instances fighting over the single privileged helper made the
    /// helper's disconnect fail-safe erase manual fan targets, so the
    /// feedback watchdog reverted manual mode within seconds (reproduced on
    /// real hardware with the max-hold probe: 2 instances → revert at 12.5s,
    /// 1 instance → stable 100% hold). The app must yield to an existing
    /// instance before creating any stores or helper connections.
    func testAppYieldsToExistingInstanceBeforeTouchingTheHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains("init() {\n        Self.terminateIfDuplicateInstance()"))
        XCTAssertTrue(app.contains("private static func terminateIfDuplicateInstance()"))
        XCTAssertTrue(app.contains("runningApplications("))
        // Startup races keep exactly one instance: only the newer one exits.
        XCTAssertTrue(app.contains("hasEarlierPeer"))
    }

    func testCapabilityKeepsAuthorizationConnectionAndModeIndependent() {
        let telemetry = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 1_620, minimum: 1_200, maximum: 4_000),
        ]))
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: telemetry, helperState: .notRegistered),
            .authorizationRequired
        )
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: telemetry, helperState: .requiresApproval),
            .requiresSystemApproval
        )
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: telemetry, helperState: .enabled),
            .controllable
        )
        XCTAssertEqual(
            FanControlCapability.resolve(telemetry: telemetry, helperState: .connectionInterrupted),
            .connectionFailed
        )
        XCTAssertEqual(
            FanStatusPresentation.monitoringTitle(
                mode: .unknown,
                capability: .connectionFailed
            ),
            L10n.text("仅监测", "Monitoring Only")
        )
        XCTAssertEqual(
            FanStatusPresentation.monitoringTitle(
                mode: .unknown,
                capability: .authorizationRequired
            ),
            L10n.text("仅监测", "Monitoring Only")
        )
        XCTAssertEqual(
            FanStatusPresentation.monitoringTitle(
                mode: .systemAutomatic,
                capability: .connectionFailed
            ),
            L10n.text("自动", "Automatic")
        )
        XCTAssertEqual(
            HelperState.connectionInterrupted.title,
            L10n.text("高级控制暂不可用", "Advanced Control Temporarily Unavailable")
        )
        XCTAssertEqual(
            FanControlCapability.connectionFailed.title,
            L10n.text("高级控制暂不可用", "Advanced Control Temporarily Unavailable")
        )
        XCTAssertEqual(
            FanControlMode.unknown.title,
            L10n.text("仅监测", "Monitoring Only")
        )
        XCTAssertEqual(FanControlMode.resolve(observedMode: nil), .unknown)
        XCTAssertEqual(FanControlMode.resolve(observedMode: .systemAutomatic), .systemAutomatic)
        XCTAssertEqual(FanControlMode.resolve(observedMode: .manual), .manual)
    }

    func testPowerCapabilityComesFromReadbackAndSupportedModes() {
        let allModes = BatteryPowerModes(
            battery: .automatic,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower]
        )
        let lowOnly = BatteryPowerModes(
            battery: .automatic,
            adapter: .lowPower,
            supportedBatteryModes: [.automatic, .lowPower],
            supportedAdapterModes: [.automatic, .lowPower]
        )
        XCTAssertEqual(
            PowerModeCapability.resolve(
                modes: allModes,
                hasCompletedRead: false,
                helperState: .enabled
            ),
            .checking
        )
        XCTAssertEqual(
            PowerModeCapability.resolve(
                modes: allModes,
                hasCompletedRead: true,
                helperState: .notRegistered
            ),
            .authorizationRequired
        )
        XCTAssertEqual(
            PowerModeCapability.resolve(
                modes: allModes,
                hasCompletedRead: true,
                helperState: .enabled
            ),
            .automaticLowAndHighPower
        )
        XCTAssertEqual(
            PowerModeCapability.resolve(
                modes: lowOnly,
                hasCompletedRead: true,
                helperState: .enabled
            ),
            .automaticAndLowPower
        )
    }

#if DEBUG
    func testAllRequiredDemoStatesResolveToConsistentProfiles() {
        XCTAssertEqual(MiniWindowDemoData.HardwareControlDemoState.allCases.count, 22)
        for state in MiniWindowDemoData.HardwareControlDemoState.allCases {
            _ = MiniWindowDemoData.hardwareControlProfile(for: state)
        }

        let manual = MiniWindowDemoData.hardwareControlProfile(for: .fanManual65)
        XCTAssertEqual(manual.observedMode, .manual)
        XCTAssertEqual(manual.manualPercentage, 65)
        XCTAssertEqual(manual.fanReadings.first?.normalizedPercent ?? -1, 65, accuracy: 0.001)

        let readOnly = MiniWindowDemoData.hardwareControlProfile(for: .fanReadOnly)
        XCTAssertNil(readOnly.fanReadings.first?.maximumRPM)
        XCTAssertNil(readOnly.fanReadings.first?.normalizedPercent)
        XCTAssertTrue(MiniWindowDemoData.hardwareControlProfile(for: .fanless).fanReadings.isEmpty)
        XCTAssertEqual(MiniWindowDemoData.hardwareControlProfile(for: .dualFan).fanReadings.count, 2)
        XCTAssertFalse(MiniWindowDemoData.hardwareControlProfile(for: .desktopMac).hasInternalBattery)
        XCTAssertFalse(
            MiniWindowDemoData.hardwareControlProfile(for: .noHighPower)
                .powerModes.supportedAdapterModes.contains(.highPower)
        )
        XCTAssertEqual(
            MiniWindowDemoData.hardwareControlProfile(for: .thermalSerious).thermalState,
            .serious
        )
        XCTAssertEqual(
            MiniWindowDemoData.hardwareControlProfile(for: .thermalCritical).thermalState,
            .critical
        )
        XCTAssertEqual(
            MiniWindowDemoData.hardwareControlProfile(for: .connectionInterrupted).helperState,
            .connectionInterrupted
        )
        let readbackFailure = MiniWindowDemoData.hardwareControlProfile(for: .fanReadbackFailed)
        XCTAssertNil(readbackFailure.observedMode)
        XCTAssertEqual(readbackFailure.message, L10n.text(
            "风扇写入回读不一致；恢复系统自动控制尚未确认。",
            "Fan readback did not match; restoration of automatic system control remains unconfirmed."
        ))
        let curve = MiniWindowDemoData.hardwareControlProfile(for: .curveActive)
        XCTAssertEqual(curve.observedMode, .customCurve)
        XCTAssertEqual(curve.curveRuntimeState.status, .active)
        XCTAssertEqual(curve.curveRuntimeState.appliedPercentage, 35)
        XCTAssertNotNil(curve.curveProfile)
        XCTAssertTrue(
            MiniWindowDemoData.hardwareControlProfile(for: .curveDraftChanges)
                .curveHasUnappliedChanges
        )
        XCTAssertEqual(
            MiniWindowDemoData.hardwareControlProfile(for: .curveSensorUnavailable)
                .curveRuntimeState.status,
            .sensorUnavailable
        )
        XCTAssertEqual(
            MiniWindowDemoData.hardwareControlProfile(for: .curveThermalProtection)
                .curveRuntimeState.status,
            .thermalProtection
        )
    }
#endif

    func testHardwareCardsShareOneDetailPageAndKeepSeparateSelection() {
        let coordinator = GeekPanelCoordinator()
        coordinator.selectHardwareDetail(.monitoring)
        XCTAssertEqual(coordinator.selectedSection, .sensors)
        XCTAssertEqual(coordinator.hardwareDetailFocus, .monitoring)

        coordinator.selectHardwareDetail(.power)
        XCTAssertEqual(coordinator.selectedSection, .sensors)
        XCTAssertEqual(coordinator.hardwareDetailFocus, .power)
        XCTAssertTrue(coordinator.isModulePinned)

        coordinator.selectHardwareDetail(.power)
        XCTAssertEqual(coordinator.route, .summary)
    }

    func testSuccessfulRestoreReplyWithoutModeReadbackKeepsAutomaticUnconfirmed() async {
        let suite = "HardwareControlPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                operations.append(request.operation)
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "verified",
                    appliedTargetRPMByFan: [:]
                )
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )

        await coordinator.selectMode(.systemAutomatic)

        XCTAssertEqual(operations, [.restoreAutomatic])
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(coordinator.lastMessage, L10n.text(
            "Helper 已确认恢复请求完成；当前硬件模式仍待确认。",
            "Helper confirmed completion of the restore request; the current hardware mode remains unconfirmed."
        ))
    }

    func testFanSpeedFormatterUsesLowercaseUnitAndStableDigits() {
        XCTAssertEqual(SystemFanSpeedFormat.number(1_620), "1,620")
        XCTAssertEqual(SystemFanSpeedFormat.string(1_620), "1,620 rpm")
        XCTAssertEqual(
            MiniWindowStyleTokens.detailRevealDelay,
            HoverIntentPolicy.menuBar.initialOpenDelay
        )
        XCTAssertEqual(
            MiniWindowStyleTokens.historyRevealDelay,
            HoverIntentPolicy.menuBar.switchDelay
        )
    }

    func testHistoryKeepsActualAndTargetRPMSeparate() {
        let point = MenuBarTelemetryPoint(snapshot: snapshot(readings: [
            SystemFanReading(
                index: 0,
                actualRPM: 2_160,
                minimumRPM: 1_200,
                maximumRPM: 6_400,
                targetRPM: 2_200
            ),
            SystemFanReading(
                index: 1,
                actualRPM: 2_400,
                minimumRPM: 1_300,
                maximumRPM: 6_800,
                targetRPM: 2_600
            ),
        ]))

        XCTAssertEqual(point.fanRPM, 2_280)
        XCTAssertEqual(point.fanTargetRPM, 2_400)
        XCTAssertEqual(MenuBarTelemetryChannel.fanTargetRPM.value(in: point), 2_400)
    }

    private func snapshot(
        readings: [SystemFanReading]?,
        fanCount: Int? = nil,
        availability: SystemSensorAvailability = .available
    ) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            metrics: [],
            networkThroughput: nil,
            fanCount: fanCount,
            fanReadings: readings,
            sensorAvailability: availability
        )
    }

    private func fan(
        index: Int = 0,
        actual: Int,
        minimum: Int?,
        maximum: Int?
    ) -> SystemFanReading {
        SystemFanReading(
            index: index,
            identity: .cpu,
            actualRPM: actual,
            minimumRPM: minimum,
            maximumRPM: maximum,
            targetRPM: actual
        )
    }
}
