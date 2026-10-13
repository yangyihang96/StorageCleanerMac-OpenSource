import XCTest
@testable import StorageCleanerMac

@MainActor
final class PowerFanRestoreTests: XCTestCase {
    func testSegmentsSelectEffectiveReadbackInsteadOfManualOrStoredTarget() throws {
        for source: BatteryChargeLimitSource in [.manual, .optimized, .manualAndOptimized, .none, .unknown] {
            let state = BatteryChargeLimitState(target: .full, availableTargets: [.protected, .full],
                effectiveLimit: 80, source: source)
            XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(state), .protected)
        }
        let temporary = BatteryChargeLimitState(target: .protected, availableTargets: [.protected, .full],
            effectiveLimit: 100, source: .manual, manualLimitTemporarilyDisabled: true)
        XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(temporary), .full)
        XCTAssertNotNil(BatteryChargeLimitPresentation.fullChargeStatus(temporary))
        XCTAssertEqual(temporary.target, .protected)
        for value: Int? in [nil, 83] {
            let state = BatteryChargeLimitState(target: .protected, availableTargets: [.protected, .full],
                effectiveLimit: value, source: .unknown)
            XCTAssertNil(BatteryChargeLimitPresentation.selectedSegment(state))
        }
        XCTAssertNil(BatteryChargeLimitPresentation.selectedSegment(nil))
        let unsupported = BatteryChargeLimitState(target: .full, availableTargets: [], effectiveLimit: 80, source: .optimized)
        XCTAssertNil(BatteryChargeLimitPresentation.selectedSegment(unsupported))
    }

    func testSourceCaptionAppearsOnlyForNonManualSources() {
        for language in [true, false] {
            func caption(_ source: BatteryChargeLimitSource) -> String? {
                BatteryChargeLimitPresentation.sourceCaption(BatteryChargeLimitState(target: .full,
                    availableTargets: [.protected, .full], effectiveLimit: 80, source: source), usesChinese: language)
            }
            XCTAssertNil(caption(.manual))
            XCTAssertNil(caption(.none))
            XCTAssertNotNil(caption(.optimized))
            XCTAssertNotNil(caption(.manualAndOptimized))
            XCTAssertNotNil(caption(.unknown))
            XCTAssertTrue(caption(.optimized)?.contains("80%") == true)
            XCTAssertFalse(caption(.optimized)?.contains("\n") == true)
        }
        XCTAssertNil(BatteryChargeLimitPresentation.sourceCaption(nil))
    }

#if DEBUG || STORAGE_CLEANER_BETA
    func testEntryRemainsReachableAndModesVisibleAcrossEveryHelperState() {
        let telemetry = MiniWindowDemoData.fanTelemetry(for: .fanAutomatic)
        for helper: HelperState in [.enabled, .notRegistered, .requiresApproval, .connectionInterrupted, .signatureRejected, .unavailable] {
            let entry = FanControlEntryPresentation(telemetry: telemetry, helperState: helper,
                observedMode: .systemAutomatic, manualPercentage: nil)
            XCTAssertTrue(entry.showsControl, "Setup failure must not hide the route")
            XCTAssertFalse(entry.status.isEmpty)
            XCTAssertEqual(FanControlPaletteAvailability.visibleModes(telemetry: telemetry), [.systemAutomatic, .customCurve, .manual, .maximum])
            for mode in FanControlPaletteAvailability.visibleModes(telemetry: telemetry) {
                XCTAssertEqual(FanControlPaletteAvailability.disabledReason(mode: mode, telemetry: telemetry, helperState: helper) == nil,
                    helper == .enabled)
            }
            if helper != .enabled {
                XCTAssertEqual(entry.status, FanControlSetupPresentation.reason(helper))
                XCTAssertFalse(FanControlSetupPresentation.actionTitle(helper).isEmpty)
            }
        }
        XCTAssertEqual(FanControlSetupPresentation.actionTitle(.notRegistered), L10n.text("启用风扇控制", "Enable Fan Control"))
        XCTAssertEqual(FanControlSetupPresentation.actionTitle(.requiresApproval), L10n.text("在系统设置中批准", "Approve in System Settings"))
        XCTAssertEqual(FanControlSetupPresentation.actionTitle(.connectionInterrupted), L10n.text("重新检测", "Check Again"))
        XCTAssertEqual(FanControlSetupPresentation.actionTitle(.signatureRejected), L10n.text("重新检测", "Check Again"))
    }

    func testEntryShowsConfirmedModeAndFanlessHasNoControlChoices() {
        let telemetry = MiniWindowDemoData.fanTelemetry(for: .fanManual65)
        let cases: [(GeekFanControlMode, Double?, String)] = [
            (.systemAutomatic, nil, L10n.text("系统自动", "System Automatic")),
            (.manual, 65, L10n.text("手动 65%", "Manual 65%")),
            (.customCurve, nil, L10n.text("自定义曲线", "Custom Curve")),
            (.manual, nil, L10n.text("手动控制", "Manual Control"))]
        for (mode, percentage, title) in cases {
            XCTAssertEqual(FanControlEntryPresentation(telemetry: telemetry, helperState: .enabled,
                observedMode: mode, manualPercentage: percentage).status, title)
        }
        let fanless = MiniWindowDemoData.fanTelemetry(for: .fanless)
        XCTAssertFalse(FanControlEntryPresentation(telemetry: fanless, helperState: .notRegistered,
            observedMode: nil, manualPercentage: nil).showsControl)
        XCTAssertEqual(FanControlPaletteAvailability.visibleModes(telemetry: fanless), [])
        XCTAssertEqual(FanControlEntryPresentation(telemetry: fanless, helperState: .notRegistered,
            observedMode: nil, manualPercentage: nil).status, L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling"))
        for mode in [GeekFanControlMode.manual, .customCurve] {
            XCTAssertNotNil(FanControlPaletteAvailability.disabledReason(mode: mode,
                telemetry: MiniWindowDemoData.fanTelemetry(for: .fanReadOnly), helperState: .enabled))
        }
    }

    func testDemoSnapshotKeepsSensorReadingsAndMatchesFanMetricsAcrossLayers() throws {
        let shown = try XCTUnwrap(MiniWindowDemoData.presentationSnapshot(live: nil, usesDemoData: true))
        XCTAssertEqual(shown.metric(for: .chipTemperature)?.value, "53°C")
        XCTAssertEqual(shown.temperatureReadings?.first { $0.zone == .gpu }?.celsius, 49)
        XCTAssertEqual(FanTelemetryState.resolve(snapshot: shown).readings, MiniWindowDemoData.hardwareControlProfile.fanReadings)
        XCTAssertNil(MiniWindowDemoData.presentationSnapshot(live: nil, usesDemoData: false))
        for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .fanMaximum, .curveActive, .fanless] {
            let fixture = MiniWindowDemoData.makeFixture(arguments: [MiniWindowDemoData.hardwareControlStateArgumentPrefix + state.rawValue])
            let snapshot = fixture.snapshot
            let fan = FanTelemetryState.resolve(snapshot: snapshot)
            XCTAssertEqual(fixture.telemetry.last?.fanRPM, fan.actualRPM.map(Double.init))
            XCTAssertEqual(fan.readings, MiniWindowDemoData.hardwareControlProfile(for: state).fanReadings)
            XCTAssertEqual(snapshot.metric(for: .fanSpeed)?.value, fan.actualRPM.map(SystemFanSpeedFormat.string) ?? "—")
            XCTAssertEqual(snapshot.metric(for: .fanSpeed)?.isAvailable, fan.telemetryAvailable)
            XCTAssertEqual(snapshot.temperatureReadings?.first { $0.zone == .gpu }?.celsius, 49)
            XCTAssertEqual(MiniWindowDemoData.presentationSnapshot(live: snapshot, usesDemoData: false), snapshot)
        }
    }

    func testDemoChargeScenariosCoverActualLimitSourcesAndTemporaryStatus() throws {
        let manual = try XCTUnwrap(MiniWindowDemoData.chargeLimitState(for: .manual80))
        XCTAssertEqual(manual.source, .manual)
        XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(manual), .protected)
        let optimized = try XCTUnwrap(MiniWindowDemoData.chargeLimitState(for: .optimized80))
        XCTAssertEqual(optimized.target, .full)
        XCTAssertEqual(optimized.source, .optimized)
        XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(optimized), .protected)
        let temporary = try XCTUnwrap(MiniWindowDemoData.chargeLimitState(for: .temporaryFullCharge))
        XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(temporary), .full)
        XCTAssertNotNil(BatteryChargeLimitPresentation.fullChargeStatus(temporary))
        XCTAssertEqual(MiniWindowDemoData.chargeLimitState(for: .unsupported)?.availableTargets, [])
        let many = try XCTUnwrap(MiniWindowDemoData.chargeLimitState(for: .manySegments))
        XCTAssertEqual(many.availableTargets.map(\.rawValue), [70, 75, 80, 85, 90, 95, 100])
        XCTAssertEqual(BatteryChargeLimitPresentation.selectedSegment(many)?.rawValue, 85)
        XCTAssertEqual(MiniWindowDemoData.chargeLimitState(arguments: ["--debug-charge-limit-state=optimized80"]), optimized)
    }
#endif
}
