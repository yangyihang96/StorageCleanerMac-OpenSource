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
    /// action. D152: the toggles switch at once through the shared gate
    /// (was a draft previewed until Apply, an expand toggle and the RPM and
    /// per-fan readback in the palette; the readback is the sensors page's).
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

        // D152: the gate is the static disabledReason every toggle reads (was
        // `private var applyDisabledReason` checking the helper and the fixture).
        XCTAssertFalse(palette.contains("private var applyDisabledReason"))
        let gate = try r2SourceDeclaration("static func disabledReason(", in: palette)
        XCTAssertTrue(gate.contains("if isDataOnlyFixture { return previewNote }"))
        XCTAssertTrue(gate.contains("FanControlPaletteAvailability.disabledReason("))
        XCTAssertTrue(gate.contains("helperState: helperState"))
        let availability = try r2SourceDeclaration("enum FanControlPaletteAvailability", in: Self.hardwareControlSource())
        XCTAssertTrue(availability.contains("if helperState != .enabled { return FanControlSetupPresentation.reason(helperState) }"),
                      "Unconnected hardware must not appear writable")
        XCTAssertTrue(palette.contains(".disabled(disabledReason(choice.mode) != nil)"))
        // D152: a toggle switches at once (was `draft.selectMode(mode)`, a preview until Apply).
        XCTAssertFalse(palette.contains("draft.selectMode(mode)"))
        XCTAssertTrue(palette.contains("await fanControl.selectMode(mode)"))
        XCTAssertTrue(palette.contains("await fanControl.applyFanCurveDraft()"))
        XCTAssertTrue(palette.contains("enable: { Task { await fanControl.registerHelper() } }"))
        // D152: no expand toggle (was `fan-control-layout-toggle`).
        XCTAssertFalse(palette.contains("fan-control-layout-toggle"))
        XCTAssertFalse(palette.contains("if showsExpandedControls, fanControl.helperState == .enabled"))
        // D152: the sections stay above the helper's setup (was the read-only
        // `Text(currentFanRPM)` above it; the palette shows no RPM now).
        let view = try r2SourceDeclaration("struct FanControlPaletteView: View", in: palette)
        XCTAssertFalse(view.contains("Text(currentFanRPM)"))
        let sectionsPosition = try XCTUnwrap(view.range(of: "ForEach(sections)")).lowerBound
        let notesPosition = try XCTUnwrap(view.range(of: "notes", range: sectionsPosition..<view.endIndex)).lowerBound
        let helperGate = try XCTUnwrap(view.range(of: "if fanControl.helperState != .enabled", range: notesPosition..<view.endIndex)).lowerBound
        XCTAssertLessThan(sectionsPosition, helperGate, "The read-only sections remain above the Helper-only action")
        // D152: per-fan readback is the sensors page's rows and hover detail (was `fanReadbackRows` in Details).
        XCTAssertFalse(palette.contains("fanReadbackRows"))
        let sensors = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sensors.contains("ForEach(geekFanTelemetry.readings.prefix(2)) { reading in"), "Per-fan readback stays on the sensors page")
        XCTAssertTrue(sensors.contains("readings: geekFanTelemetry.readings,"))
    }

    private static func hardwareControlSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHardwareControlView.swift"
            ),
            encoding: .utf8
        )
    }

    func testConnectedHelperDoesNotTurnReadOnlyTelemetryOrUnknownModeIntoControl() {
        let telemetry = FanTelemetryState.resolve(snapshot: snapshot(readings: [
            fan(actual: 0, minimum: nil, maximum: nil),
        ]))
        let capability = FanControlCapability.resolve(telemetry: telemetry, helperState: .enabled)
        XCTAssertEqual(capability, .readOnly)
        XCTAssertEqual(FanStatusPresentation.controlTitle(capability), L10n.text("只读", "Read Only"))
        // D152: the palette's details that showed the connection and the
        // approval left with F7 (were connectionTitle(.enabled) 已连接 /
        // Connected, approvalTitle(.enabled) 已批准 / Approved and
        // approvalTitle(.requiresApproval) 等待批准 / Awaiting Approval). A
        // connected helper still turns read-only telemetry into no control:
        // every toggle but Automatic stays off-limits.
        for mode in [GeekFanControlMode.customCurve, .manual, .maximum] {
            XCTAssertEqual(
                FanControlPaletteView.disabledReason(
                    mode: mode, telemetry: telemetry, helperState: .enabled, thermalState: .nominal,
                    isDataOnlyFixture: false, curveIsAvailable: true
                ),
                L10n.text("风扇量程不可用 · 仅监测", "Fan Range Unavailable · Monitoring Only"),
                "\(mode)"
            )
        }
        XCTAssertNil(FanControlPaletteView.disabledReason(
            mode: .systemAutomatic, telemetry: telemetry, helperState: .enabled, thermalState: .nominal,
            isDataOnlyFixture: false, curveIsAvailable: true
        ))
        XCTAssertEqual(
            FanControlPaletteView.disabledReason(
                mode: .manual, telemetry: telemetry, helperState: .requiresApproval, thermalState: .nominal,
                isDataOnlyFixture: false, curveIsAvailable: true
            ),
            FanControlSetupPresentation.reason(.requiresApproval)
        )
        XCTAssertEqual(FanStatusPresentation.confirmedModeTitle(nil), "—")
        XCTAssertEqual(FanStatusPresentation.confirmedModeTitle(.manual), FanControlMode.manual.title)
        XCTAssertEqual(FanStatusPresentation.controlTitle(.controllable), L10n.text("可提交控制", "Ready to Submit"))
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

        // D106: only the Beta's acceptance check may come first. It exits
        // when any other copy runs, without activating it, and creates no
        // store or helper connection.
        XCTAssertTrue(app.contains(
            "init() {\n#if STORAGE_CLEANER_BETA\n        // D106: first, so a refused acceptance launch exits before any\n        // window, status item, store or helper connection exists.\n        AcceptanceLaunch.configureOrExit()\n#endif\n        Self.terminateIfDuplicateInstance()"
        ))
        let acceptance = SwiftSourceScanning.code(try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Support/AcceptanceLaunch.swift"),
            encoding: .utf8
        ))
        let check = try SwiftSourceScanning.body(of: "static func configureOrExit()", in: acceptance)
        for touched in ["Coordinator", "Store", "NSXPCConnection", "SMAppService", ".activate()", "activate(options"] {
            XCTAssertFalse(check.contains(touched), touched)
        }
        XCTAssertTrue(check.contains("runningApplications(withBundleIdentifier: identifier)"))
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
        XCTAssertEqual(MiniWindowDemoData.HardwareControlDemoState.allCases.count, 26)
        for state in MiniWindowDemoData.HardwareControlDemoState.allCases {
            _ = MiniWindowDemoData.hardwareControlProfile(for: state)
        }

        // D73 adds trust failure and unavailable helper fixtures without dropping any old case.
        XCTAssertEqual(MiniWindowDemoData.hardwareControlProfile(for: .helperUntrusted).helperState, .signatureRejected)
        XCTAssertNil(MiniWindowDemoData.hardwareControlProfile(for: .helperUntrusted).observedMode)
        XCTAssertEqual(MiniWindowDemoData.hardwareControlProfile(for: .helperUnavailable).helperState, .unavailable)
        XCTAssertNil(MiniWindowDemoData.hardwareControlProfile(for: .helperUnavailable).observedMode)

        let maximum = MiniWindowDemoData.hardwareControlProfile(for: .fanMaximum)
        XCTAssertEqual(maximum.observedMode, .maximum)
        XCTAssertEqual(maximum.fanReadings.first?.actualRPM, maximum.fanReadings.first?.maximumRPM)

        let manual = MiniWindowDemoData.hardwareControlProfile(for: .fanManual65)
        XCTAssertEqual(manual.observedMode, .manual)
        XCTAssertEqual(manual.manualPercentage, 65)
        XCTAssertEqual(manual.fanReadings.first?.normalizedPercent ?? -1, 65, accuracy: 0.001)

        let readOnly = MiniWindowDemoData.hardwareControlProfile(for: .fanReadOnly)
        XCTAssertNil(readOnly.fanReadings.first?.maximumRPM)
        XCTAssertNil(readOnly.fanReadings.first?.normalizedPercent)
        XCTAssertTrue(MiniWindowDemoData.hardwareControlProfile(for: .fanless).fanReadings.isEmpty)
        XCTAssertEqual(MiniWindowDemoData.hardwareControlProfile(for: .dualFan).fanReadings.count, 2)
        // Review P2-2: manual control with two fans, the state that shows the
        // "双风扇同步" switch in screenshots.
        let dualManual = MiniWindowDemoData.hardwareControlProfile(for: .dualFanManual)
        XCTAssertEqual(dualManual.observedMode, .manual)
        XCTAssertEqual(dualManual.manualPercentage, 65)
        XCTAssertEqual(dualManual.fanReadings.count, 2)
        for reading in dualManual.fanReadings {
            XCTAssertEqual(reading.normalizedPercent ?? -1, 65, accuracy: 0.001)
        }
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
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = TestPreferenceDomain.open(suiteName: suite)!
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
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
