#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D152: iStat Menus 7.30's fan submenu — a text section per mode with
/// iStat's switch on its major label (Automatic, Custom Fan Curve, Manual
/// and our Maximum), the Sync tick row and the sliders in the manual
/// section; the subtitles stay AX hints (D64). Was UI plan U1 117/118's
/// single-choice cards (icon, title, a round selection mark on the right)
/// and a switch for synchronising the fans. Only the views are rendered
/// here, with read-only fixtures or coordinators whose transport fails the
/// test or refuses the ping; no hardware call is involved.
@MainActor
final class FanControlModeCardTests: XCTestCase {
    /// D152: iStat's titles (自动 / Automatic, 自定义风扇曲线 / Custom Fan
    /// Curve, 手动 / Manual) and our Maximum, in iStat's order, without icons
    /// (were 自动控制 and 手动控制 with the sensors, advanced and settings
    /// symbols).
    func testPaletteOffersFourSingleChoiceModesWithIconTitleAndSubtitle() throws {
        XCTAssertEqual(FanControlModeChoice.allCases.map(\.mode), [.systemAutomatic, .customCurve, .manual, .maximum])
        XCTAssertEqual(FanControlModeChoice(mode: .systemAutomatic), .automatic)
        XCTAssertEqual(FanControlModeChoice(mode: .customCurve), .curve)
        XCTAssertEqual(FanControlModeChoice(mode: .manual), .manual)
        XCTAssertEqual(FanControlModeChoice(mode: .maximum), .maximum)
        XCTAssertEqual(FanControlModeChoice.maximum.title, GeekFanControlMode.maximum.title)
        XCTAssertEqual(FanControlModeChoice.maximum.subtitle, L10n.text("所有风扇使用硬件最大转速", "Use the hardware maximum RPM for every fan"))
        XCTAssertNil(FanControlModeChoice(mode: .fanSet))

        XCTAssertEqual(FanControlModeChoice.automatic.title, L10n.text("自动", "Automatic"))
        XCTAssertEqual(FanControlModeChoice.automatic.subtitle, L10n.text("交给 macOS 动态调节", "macOS adjusts the fans"))
        XCTAssertEqual(FanControlModeChoice.curve.title, L10n.text("自定义风扇曲线", "Custom Fan Curve"))
        XCTAssertEqual(FanControlModeChoice.curve.subtitle, L10n.text("按温度曲线调节转速", "Follows a temperature curve"))
        XCTAssertEqual(FanControlModeChoice.manual.title, L10n.text("手动", "Manual"))
        XCTAssertEqual(FanControlModeChoice.manual.subtitle, L10n.text("直接设置目标转速", "Set a target speed directly"))
        let choice = try r2SourceDeclaration("enum FanControlModeChoice",
            in: try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"))
        XCTAssertFalse(choice.contains("systemImage"))
    }

    func testEntryAXPressPresentsFanPaletteAcrossSetupStates() async throws {
        for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .fanMaximum, .curveActive,
                .helperNotRegistered, .awaitingSystemApproval, .connectionInterrupted, .helperUntrusted, .helperUnavailable] {
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let entry = FanControlEntryPresentation(telemetry: MiniWindowDemoData.fanTelemetry(for: state),
                helperState: profile.helperState, observedMode: profile.observedMode, manualPercentage: profile.manualPercentage)
            for isHeader in [false, true] {
                let coordinator = ControlPaletteCoordinator(
                    fixedVisibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900), presentsPanelOnShow: false)
                defer { coordinator.dismiss() }
                let fixture = FanCardAccessibilityFixture(root: FanControlEntryRow(state: entry, isHeader: isHeader)
                    .environment(\.controlPaletteCoordinator, coordinator)
                    .environment(\.accessibilityEnabled, true))
                defer { fixture.close() }
                let button = try await fixture.button(label: L10n.text("风扇控制", "Fan Control"))
                XCTAssertEqual(fixture.text(button, "accessibilityValue"), entry.status)
                XCTAssertTrue(try fixture.press(button))
                for _ in 0..<50 where coordinator.state.kind != .fan {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(coordinator.state.kind, .fan, "Click must call the real presentation path for \(state)")
                XCTAssertEqual(coordinator.presentationCount, 1)
                XCTAssertTrue(coordinator.isPresented)
            }
        }
    }

    /// D152: the four sections stay visible in every setup state. A
    /// fixture's switches are off-limits behind the preview note and change
    /// nothing; the switch that is on is the fixture's mode; the manual
    /// section holds the fans' slider; the helper's setup keeps its action
    /// below the sections; there is no Apply and no Edit Curve (was: setup
    /// blocked the cards with its reason as help and a status capsule, and
    /// with the helper enabled the manual card showed Apply and the speed
    /// control, Maximum was selectable and the curve card's Edit Curve
    /// opened the editor page).
    func testPaletteModesStayVisibleButSetupBlocksSelectionAndManualShowsApply() async throws {
        for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .fanMaximum, .helperNotRegistered,
                .awaitingSystemApproval, .connectionInterrupted, .helperUntrusted, .helperUnavailable] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let snapshot = MiniWindowDemoData.fixture.snapshot
            let fanControl = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile, snapshot: snapshot)
            let selectedMode = fanControl.selectedMode
            let percentage = fanControl.manualPercentage(for: nil)
            let presentation = ControlPalettePresentationState()
            presentation.present(.fan)
            let view = FanControlPaletteView(presentation: presentation, fanControl: fanControl,
                telemetry: MiniWindowDemoData.fanTelemetry(for: state), thermalState: .nominal)
                .frame(width: ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding)
                .environment(\.accessibilityEnabled, true)
            let fixture = FanCardAccessibilityFixture(root: view, height: 560)
            defer { fixture.close() }
            let displayed = FanControlPaletteView.displayedMode(requested: nil, selected: selectedMode)
            for choice in FanControlModeChoice.allCases {
                let toggle = try await fixture.element(identifier: "fan-mode-" + choice.mode.rawValue)
                let tag = "\(state) \(choice)"
                XCTAssertEqual(fixture.text(toggle, "accessibilityLabel"), choice.title, tag)
                XCTAssertEqual(fixture.text(toggle, "accessibilityHelp"), FanControlPaletteView.previewNote, tag)
                // A native toggle: VoiceOver reads the state from its value.
                XCTAssertEqual(fixture.text(toggle, "accessibilityRole"), NSAccessibility.Role.checkBox.rawValue, tag)
                XCTAssertEqual(fixture.text(toggle, "accessibilitySubrole"), NSAccessibility.Subrole.toggle.rawValue, tag)
                XCTAssertEqual(fixture.number(toggle, "accessibilityValue"), choice.mode == displayed ? 1 : 0, tag)
                XCTAssertEqual(try fixture.isEnabled(toggle), false, "\(tag): a preview disables every switch")
                _ = try fixture.press(toggle)
            }
            let slider = try await fixture.element(identifier: "fan-manual-slider--1")
            XCTAssertEqual(fixture.text(slider, "accessibilityLabel"), L10n.text("风扇", "Fans"))
            // The percentage is the adjustable element's value description,
            // as the slider before D152 exposed it.
            XCTAssertEqual(fixture.text(slider, "accessibilityValueDescription"),
                           FanControlSliderGeometry.valueText(fraction: percentage / 100))
            if profile.helperState != .enabled {
                // D152: the setup note below the sections names the setup step
                // (was the status capsule's capsuleTitle).
                XCTAssertTrue(fixture.contains(text: FanControlSetupPresentation.reason(profile.helperState)),
                    "The setup note must describe setup, not show a dash")
                _ = try await fixture.button(label: FanControlSetupPresentation.actionTitle(profile.helperState))
            }
            XCTAssertFalse(fixture.contains(text: L10n.text("应用", "Apply")))
            XCTAssertFalse(fixture.contains(text: L10n.text("编辑曲线", "Edit Curve")))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(fanControl.requestedMode, "Preview and disabled controls must never send a write")
            XCTAssertEqual(fanControl.selectedMode, selectedMode)
            XCTAssertEqual(fanControl.observedMode, profile.observedMode)
        }
    }

    /// D149: the targets are one row of segments again (D124 had tick rows).
    /// The manual limit macOS reads back is selected (100 % when none is
    /// set), whatever the effective limit (was: only the effective limit); a
    /// segment writes its target once, never asks for a temporary full
    /// charge, and an unconfirmed write selects nothing.
    func testChargeSegmentsSelectTheManualReadbackAndDoNotHighlightUnconfirmedWrites() async throws {
        let targets = [80, 90, 100].compactMap(BatteryChargeTarget.init(rawValue:))
        let labels = targets.map { BatteryChargeLimitPresentation.manualTargetLabel($0) }
        XCTAssertEqual(labels, ["80%", "90%", "100%"])
        let selected = L10n.text("已选择", "Selected")
        let notSelected = L10n.text("未选择", "Not Selected")
        for effective: Int? in [80, 100, nil, 83] {
            let state = BatteryChargeLimitState(target: .full, availableTargets: targets,
                effectiveLimit: effective, source: .optimized)
            let calls = ChargeSegmentTestCalls()
            let view = GeekEnergyModeHoverDetail(batteryMode: nil, batterySupportedModes: [],
                adapterMode: nil, adapterSupportedModes: [], powerSource: .acPower,
                isCharging: false, showsChargeTargetSetting: true, showsFullChargeAction: true,
                chargeLimitState: state, batteryPowerWatts: nil, adapterPowerWatts: nil,
                adjustmentState: .idle, controlsEnabled: false, chargeLimitControlsEnabled: true,
                onChargeToFull: { calls.fullCharge += 1; return .accepted },
                onSetChargeTarget: { calls.targets.append($0); return .applied },
                onOpenBatterySettings: {}, onChangeMode: { _, _ in })
                .frame(width: ControlPaletteMetrics.powerSize.width - 2 * GeekPanelLayout.contentPadding)
            let fixture = FanCardAccessibilityFixture(root: view, height: 240)
            defer { fixture.close() }
            for (target, label) in zip(targets, labels) {
                let row = try await fixture.button(label: label)
                XCTAssertEqual(fixture.text(row, "accessibilityValue"),
                               target == .full ? selected : notSelected,
                               "Only the manual limit read back may be selected")
            }
            let middle = try await fixture.button(label: labels[1])
            XCTAssertTrue(try fixture.press(middle))
            for _ in 0..<50 where calls.targets.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(calls.targets, [targets[1]])
            XCTAssertEqual(calls.fullCharge, 0, "A target row must never request temporary full charge")
            // The closure reports applied, but the supplied system reading has not changed.
            // A new layout must keep the selection on that reading rather than the request.
            let readback = try await fixture.button(label: labels[1])
            XCTAssertEqual(fixture.text(readback, "accessibilityValue"), notSelected)
        }
    }

    /// D149: the segments follow the write permission in both appearances
    /// (D124: tick rows); the selection stays on the readback either way.
    func testWritableChargeSegmentAppearanceUsesEnabledNativeControls() async throws {
        for dark in [false, true] {
            for writable in [false, true] {
                let state = BatteryChargeLimitState(target: .protected, availableTargets: [.protected, .full],
                    effectiveLimit: 80, source: .manual)
                let view = GeekEnergyModeHoverDetail(batteryMode: nil, batterySupportedModes: [],
                    adapterMode: nil, adapterSupportedModes: [], powerSource: .acPower,
                    isCharging: false, showsChargeTargetSetting: true, showsFullChargeAction: true,
                    chargeLimitState: state, batteryPowerWatts: nil, adapterPowerWatts: nil,
                    adjustmentState: .idle, controlsEnabled: false, chargeLimitControlsEnabled: writable,
                    onChargeToFull: { XCTFail("Appearance check must never write"); return .accepted },
                    onSetChargeTarget: { _ in XCTFail("Appearance check must never write"); return .applied },
                    onOpenBatterySettings: {}, onChangeMode: { _, _ in })
                    .frame(width: ControlPaletteMetrics.powerSize.width - 2 * GeekPanelLayout.contentPadding)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let fixture = FanCardAccessibilityFixture(root: view, height: 200)
                defer { fixture.close() }
                let protected = try await fixture.button(label: "80%")
                let full = try await fixture.button(label: "100%")
                XCTAssertEqual(try fixture.isEnabled(protected), writable)
                XCTAssertEqual(try fixture.isEnabled(full), writable)
                XCTAssertEqual(fixture.text(protected, "accessibilityValue"), L10n.text("已选择", "Selected"))
                XCTAssertEqual(fixture.text(full, "accessibilityValue"), L10n.text("未选择", "Not Selected"))
                if let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_FIX1_EVIDENCE"] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("charge-\(writable ? "writable" : "readonly")-\(dark ? "dark" : "light").png")
                    try fixture.savePNG(to: url)
                }
            }
        }
    }

    func testCompactManualHeightKeepsOriginalBudgetWithoutScreenPlacement() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = FanCardLanguageScope(language)
            defer { scope.restore() }
            for dark in [false, true] {
                for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .dualFanManual] {
                    for synchronized in state == .dualFanManual ? [true, false] : [true] {
                        let suite = TestPreferenceDomain.makeSuite()
                        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
                        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
                        let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
                        // D152: a fixture refuses Sync like every write, so the
                        // stored preference sets it (was setManualFansSynchronized
                        // on the fixture).
                        defaults.set(synchronized, forKey: FanControlPreferences.manualSyncKey)
                        let fanControl = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile,
                            snapshot: MiniWindowDemoData.makeFixture(arguments: [MiniWindowDemoData.hardwareControlStateArgumentPrefix + state.rawValue]).snapshot)
                        XCTAssertEqual(fanControl.synchronizesManualFans, synchronized)
                        let presentation = ControlPalettePresentationState()
                        presentation.present(.fan)
                        let recorder = FanCardFrameRecorder()
                        let root = FanControlPaletteView(presentation: presentation, fanControl: fanControl,
                            telemetry: MiniWindowDemoData.fanTelemetry(for: state), thermalState: .nominal)
                            .controlSize(.small)
                            .padding(GeekPanelLayout.contentPadding)
                            .frame(width: ControlPaletteMetrics.fanSize.width)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutProbe("fix1.palette")
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                                Task { @MainActor in recorder.frames = frames }
                            }
                        let host = FanCardHost(root: root, size: CGSize(width: 280, height: 560))
                        defer { host.close() }
                        let frames = try await host.frames(from: recorder, required: ["fix1.palette"])
                        let height = try XCTUnwrap(frames["fix1.palette"]).height
                        let budget: CGFloat = state == .fanAutomatic ? 230 : (state == .dualFanManual ? 276 : 280)
                        XCTAssertLessThanOrEqual(height, budget, "\(state) \(language) dark=\(dark) sync=\(synchronized)")
                        print("fix1 compact native height: \(state) \(language) dark=\(dark) sync=\(synchronized) \(height)")
                        XCTAssertNil(fanControl.requestedMode)
                        XCTAssertEqual(fanControl.observedMode, profile.observedMode)
                    }
                }
            }
        }
    }

    func testOverviewEntryLivesInsideTheSensorCardWithoutIncreasingItsFootprint() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = FanCardLanguageScope(language)
            defer { scope.restore() }
            for width: CGFloat in [248, 280, 304, 312, 320, 360, 400] {
                for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .fanMaximum, .curveActive,
                        .helperNotRegistered, .awaitingSystemApproval, .connectionInterrupted, .helperUntrusted, .helperUnavailable] {
                    let telemetry = MiniWindowDemoData.fanTelemetry(for: state)
                    let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
                    let entry = FanControlEntryPresentation(telemetry: telemetry, helperState: profile.helperState,
                        observedMode: profile.observedMode, manualPercentage: profile.manualPercentage)
                    let recorder = FanCardFrameRecorder()
                    let root = GeekSensorsPresentation(geekCompactTemperatureText: "53°C", geekCompactFrequencyText: "3.60 GHz",
                        temperatureProgress: 0.53, temperatureTint: .accentColor, geekOverviewGPUTemperature: 49,
                        gpuUsageText: "42%", gpuUsageProgress: 0.42, resolvedGPUTint: .accentColor,
                        geekFanTelemetry: telemetry, openDetail: {}, fanControlEntry: entry)
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                            Task { @MainActor in recorder.frames = frames }
                        }
                    let host = FanCardHost(root: root, size: CGSize(width: width, height: 200))
                    defer { host.close() }
                    // D118 (old: `overview.sensor.header`, the card's title row
                    // with the "风扇控制 · 状态" button at its trailing end): the
                    // card has no title; the fan control is iStat's card menu,
                    // the "⋮" in the card's top-left 24 pt corner, and its
                    // label and status are the button's help and VoiceOver value.
                    let frames = try await host.frames(from: recorder, required: ["overview.sensor.card", "overview.sensor.entry", "overview.sensor.cpu"])
                    let card = try XCTUnwrap(frames["overview.sensor.card"])
                    let row = try XCTUnwrap(frames["overview.sensor.entry"])
                    let ring = try XCTUnwrap(frames["overview.sensor.cpu"])
                    XCTAssertEqual(card.height, GeekPanelLayout.overviewSensorsCardHeight, accuracy: 0.5)
                    XCTAssertEqual(row.width, GeekIStatCardMenuButton.side, accuracy: 0.5)
                    XCTAssertEqual(row.height, GeekIStatCardMenuButton.side, accuracy: 0.5)
                    // D119 (old value: 24): a secondary-page fan row is iStat's
                    // 15 pt row; its hit area covers the 17 pt pitch.
                    XCTAssertEqual(FanControlEntryRow.height, 15, "Secondary-page rows are iStat's rows")
                    XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(row))
                    XCTAssertEqual(row.minX, card.minX, accuracy: 0.5)
                    XCTAssertEqual(row.minY, card.minY, accuracy: 0.5)
                    // The entry adds no row: the rings keep iStat's place in the
                    // 88 pt card, 72 pt and vertically centered.
                    XCTAssertEqual(ring.height, GeekIStatCardGeometry.sensorRingSize, accuracy: 0.5)
                    XCTAssertEqual(ring.midY - card.minY, GeekIStatCardGeometry.sensorsHeight / 2, accuracy: 0.5)
                }
            }
        }
    }

    /// D152: each mode is iStat's text section: the major label row 15 tall
    /// at 5 with the switch 26 × 14 at W − 34, 25 tall alone and 73 with one
    /// fan's manual rows (5 + 15 + 2 + 16 + 30 + 5), the switch in the same
    /// place on or off (was a card with an icon, the title and a round 16 pt
    /// mark 8 from its trailing edge, at least 35.5 tall).
    func testModeCardDrawsARoundSelectionMarkOnTheRight() async throws {
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: [
                SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
            ]))
        let width = ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding
        let required = Set(FanControlModeChoice.allCases.flatMap {
            ["fan.section." + $0.mode.rawValue, "fan.mode.switch." + $0.mode.rawValue]
        })
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = FanCardLanguageScope(language)
            defer { languageScope.restore() }
            for selected in FanControlModeChoice.allCases {
                let suite = TestPreferenceDomain.makeSuite()
                let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
                defer { TestPreferenceDomain.cleanup(suiteName: suite) }
                let fanControl = FanControlCoordinator(
                    defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                    requestSender: { _ in XCTFail("Layout inspection must not reach the helper"); throw CancellationError() },
                    legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                    serviceStatusProvider: { .enabled },
                    serviceRegistrar: { XCTFail("Layout inspection must not register Helper") })
                defer { fanControl.disconnectForTermination() }
                fanControl.selectedMode = selected.mode
                let recorder = FanCardFrameRecorder()
                let root = FanControlPaletteView(presentation: ControlPalettePresentationState(), fanControl: fanControl,
                    telemetry: telemetry, thermalState: .nominal)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in recorder.frames = frames }
                    }
                let host = FanCardHost(root: root, size: CGSize(width: 260, height: 400))
                defer { host.close() }
                let frames = try await host.frames(from: recorder, required: required)
                for choice in FanControlModeChoice.allCases {
                    let tag = "\(choice) on=\(selected) \(language)"
                    let section = try XCTUnwrap(frames["fan.section." + choice.mode.rawValue])
                    let toggle = try XCTUnwrap(frames["fan.mode.switch." + choice.mode.rawValue])
                    XCTAssertEqual(section.width, width, accuracy: 0.5, tag)
                    XCTAssertEqual(section.height, choice == .manual ? 73 : 25, accuracy: 0.5, tag)
                    XCTAssertEqual(toggle.width, GeekIStatTextSectionGeometry.toggleTrackSize.width, accuracy: 0.5, tag)
                    XCTAssertEqual(toggle.height, GeekIStatTextSectionGeometry.toggleTrackSize.height, accuracy: 0.5, tag)
                    XCTAssertEqual(toggle.maxX, section.maxX - GeekIStatTextSectionGeometry.leading, accuracy: 0.5,
                                   "The switch sits on the right: \(tag)")
                    XCTAssertEqual(toggle.midY, section.minY + GeekIStatTextSectionGeometry.top
                                   + GeekIStatTextSectionGeometry.rowHeight / 2, accuracy: 0.5, tag)
                }
                XCTAssertNil(fanControl.requestedMode)
                XCTAssertEqual(fanControl.selectedMode, selected.mode)
            }
        }
    }

    /// D152: each mode's switch is one native toggle (AXCheckBox with the
    /// AXToggle subrole): the title, the subtitle as its help and 1 or 0 as
    /// its value. A VoiceOver press (AXPress) on a switch that is off
    /// chooses the mode at once, which starts with the helper's ping (the
    /// test refuses it); one that is on does nothing, as iStat's handler
    /// returns (was the card's press running the selection callback either
    /// way, reading Selected or Not Selected).
    func testVoiceOverPressChoosesTheMode() async throws {
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: [
                SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
            ]))
        for selected in [false, true] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            var operations: [FanControlHelperRequest.Operation] = []
            let fanControl = FanControlCoordinator(
                defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                requestSender: { request in
                    operations.append(request.operation)
                    return FanControlHelperReply(operation: request.operation, success: false,
                        message: "test refuses", appliedTargetRPMByFan: [:])
                },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled },
                serviceRegistrar: { XCTFail("A VoiceOver press must not register Helper") })
            defer { fanControl.disconnectForTermination() }
            if selected {
                fanControl.selectedMode = .manual
            }
            let view = FanControlPaletteView(presentation: ControlPalettePresentationState(), fanControl: fanControl,
                telemetry: telemetry, thermalState: .nominal)
                .frame(width: ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding)
                .fixedSize(horizontal: false, vertical: true)
                // SwiftUI builds its native accessibility tree only when asked to.
                .environment(\.accessibilityEnabled, true)
            let fixture = FanCardAccessibilityFixture(root: view, height: 300)
            defer { fixture.close() }
            let element = try await fixture.element(identifier: "fan-mode-" + GeekFanControlMode.manual.rawValue)
            XCTAssertEqual(fixture.text(element, "accessibilityLabel"), FanControlModeChoice.manual.title)
            XCTAssertEqual(fixture.text(element, "accessibilityHelp"), FanControlModeChoice.manual.subtitle)
            XCTAssertEqual(fixture.text(element, "accessibilityRole"), NSAccessibility.Role.checkBox.rawValue)
            XCTAssertEqual(fixture.text(element, "accessibilitySubrole"), NSAccessibility.Subrole.toggle.rawValue)
            XCTAssertEqual(fixture.number(element, "accessibilityValue"), selected ? 1 : 0)
            let pressed = try fixture.press(element)
            if selected {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(operations.isEmpty, "The switch that is on does nothing")
                XCTAssertEqual(fanControl.selectedMode, .manual)
            } else {
                XCTAssertTrue(pressed, "AXPress must be handled")
                for _ in 0..<50 where operations.isEmpty {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(operations.first, .ping, "A VoiceOver press must choose the mode")
                for _ in 0..<50 where fanControl.isSwitchingMode {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(fanControl.selectedMode, .systemAutomatic, "The refused ping keeps automatic")
                XCTAssertFalse(operations.contains(.apply))
            }
        }
    }

    /// D152: iStat's Sync tick row in the manual section, 15 tall, reads
    /// Selected or Not Selected. A VoiceOver press switches between the
    /// shared slider and one per fan, stored outside manual mode, without
    /// moving the row; disabled in a preview it changes nothing (was the
    /// 24 pt 同步所有风扇 switch reading On or Off over a draft).
    func testVoiceOverPressTogglesFanSyncWithoutMovingTheSwitch() async throws {
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: [
                SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
                SystemFanReading(index: 1, actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil),
            ]))
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = FanCardLanguageScope(language)
            defer { languageScope.restore() }
            for disabled in [false, true] {
                let suite = TestPreferenceDomain.makeSuite()
                let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
                defer { TestPreferenceDomain.cleanup(suiteName: suite) }
                let fanControl: FanControlCoordinator
                if disabled {
                    let profile = MiniWindowDemoData.hardwareControlProfile(for: .dualFan)
                    fanControl = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile,
                        snapshot: MiniWindowDemoData.fixture.snapshot)
                } else {
                    fanControl = FanControlCoordinator(
                        defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                        requestSender: { _ in XCTFail("Sync outside manual mode must not reach the helper"); throw CancellationError() },
                        legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                        serviceStatusProvider: { .enabled },
                        serviceRegistrar: { XCTFail("Sync must not register Helper") })
                }
                defer { fanControl.disconnectForTermination() }
                let recorder = FanCardFrameRecorder()
                let root = FanControlPaletteView(presentation: ControlPalettePresentationState(), fanControl: fanControl,
                    telemetry: telemetry, thermalState: .nominal)
                    .frame(width: ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.accessibilityEnabled, true)
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in recorder.frames = frames }
                    }
                let fixture = FanCardAccessibilityFixture(root: root, height: 360)
                defer { fixture.close() }
                let label = L10n.text("同步", "Sync")
                let button = try await fixture.element(identifier: "fan-manual-sync")
                XCTAssertEqual(fixture.text(button, "accessibilityLabel"), label)
                XCTAssertEqual(fixture.text(button, "accessibilityValue"), L10n.text("已选择", "Selected"))
                XCTAssertEqual(try fixture.isEnabled(button), !disabled, "A preview disables Sync")
                let original = try await fixture.syncFrame(from: recorder)
                XCTAssertEqual(original.height, GeekIStatTextSectionGeometry.rowHeight, accuracy: 0.5, "iStat's 15 pt tick row")
                let pressed = try fixture.press(button)
                if disabled {
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertTrue(fanControl.synchronizesManualFans, "Disabled AXPress must not change Sync")
                } else {
                    XCTAssertTrue(pressed)
                    for _ in 0..<100 where fanControl.synchronizesManualFans {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertFalse(fanControl.synchronizesManualFans)
                    let offButton = try await fixture.element(identifier: "fan-manual-sync")
                    XCTAssertEqual(fixture.text(offButton, "accessibilityValue"), L10n.text("未选择", "Not Selected"))
                    let unsynchronized = try await fixture.syncFrame(from: recorder)
                    XCTAssertEqual(unsynchronized.minY, original.minY, accuracy: 0.5,
                        "The per-fan sliders must not shift the row down")
                    XCTAssertEqual(unsynchronized.height, original.height, accuracy: 0.5)
                    XCTAssertEqual(unsynchronized.maxX, original.maxX, accuracy: 0.5,
                        "The row keeps the section's trailing edge")
                    XCTAssertTrue(try fixture.press(offButton))
                    for _ in 0..<100 where !fanControl.synchronizesManualFans {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(fanControl.synchronizesManualFans)
                    let synchronized = try await fixture.syncFrame(from: recorder)
                    XCTAssertEqual(synchronized.minY, original.minY, accuracy: 0.5)
                    XCTAssertEqual(synchronized.maxX, original.maxX, accuracy: 0.5)
                }
                XCTAssertEqual(fanControl.selectedMode, .systemAutomatic, "AXPress changes only the stored Sync")
                XCTAssertNil(fanControl.requestedMode)
            }
        }
    }

    /// D152: apart, each fan's slider reads its own stored value under the
    /// fan's name and a VoiceOver step (5 %) stores only that fan's;
    /// synchronized, the one Fans slider reads and steps the shared value.
    /// Outside manual mode a step reaches no helper.
    func testVoiceOverReadsAndStepsEachFansSlider() async throws {
        let readings = [
            SystemFanReading(index: 0, identity: .cpu, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
            SystemFanReading(index: 1, identity: .gpu, actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil),
        ]
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: readings))
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = FanCardLanguageScope(language)
            defer { languageScope.restore() }
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let fanControl = FanControlCoordinator(
                defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                requestSender: { _ in XCTFail("A step outside manual mode must not reach the helper"); throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled },
                serviceRegistrar: { XCTFail("A step must not register Helper") })
            defer { fanControl.disconnectForTermination() }
            fanControl.commitManualPercentage(40)
            fanControl.setManualFansSynchronized(false)
            fanControl.commitManualPercentage(25, fanID: 0)
            fanControl.commitManualPercentage(75, fanID: 1)
            let root = FanControlPaletteView(presentation: ControlPalettePresentationState(), fanControl: fanControl,
                telemetry: telemetry, thermalState: .nominal)
                .frame(width: ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            let fixture = FanCardAccessibilityFixture(root: root, height: 360)
            defer { fixture.close() }
            for (fanID, value) in [(0, "25%"), (1, "75%")] {
                let slider = try await fixture.element(identifier: "fan-manual-slider-\(fanID)")
                XCTAssertEqual(fixture.text(slider, "accessibilityLabel"), readings[fanID].displayName)
                XCTAssertEqual(fixture.text(slider, "accessibilityValueDescription"), value)
            }
            let second = try await fixture.element(identifier: "fan-manual-slider-1")
            XCTAssertTrue(try fixture.perform("accessibilityPerformIncrement", on: second))
            let first = try await fixture.element(identifier: "fan-manual-slider-0")
            XCTAssertTrue(try fixture.perform("accessibilityPerformDecrement", on: first))
            for _ in 0..<100 where fanControl.manualPercentage(for: 0) > 20.5 || fanControl.manualPercentage(for: 1) < 79.5 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(fanControl.manualPercentage(for: 0), 20, accuracy: 1e-9)
            XCTAssertEqual(fanControl.manualPercentage(for: 1), 80, accuracy: 1e-9)
            XCTAssertEqual(fanControl.manualPercentage(for: nil), 40, accuracy: 1e-9, "a fan's step leaves the shared value")
            var shown: String?
            for _ in 0..<100 where shown != "80%" {
                let slider = try await fixture.element(identifier: "fan-manual-slider-1")
                shown = fixture.text(slider, "accessibilityValueDescription")
                if shown != "80%" { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertEqual(shown, "80%", "the slider reads the stored step")
            fanControl.setManualFansSynchronized(true)
            let shared = try await fixture.element(identifier: "fan-manual-slider--1")
            XCTAssertEqual(fixture.text(shared, "accessibilityLabel"), L10n.text("风扇", "Fans"))
            XCTAssertEqual(fixture.text(shared, "accessibilityValueDescription"), "40%")
            XCTAssertTrue(try fixture.perform("accessibilityPerformIncrement", on: shared))
            for _ in 0..<100 where fanControl.manualPercentage(for: nil) < 44.5 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(fanControl.manualPercentage(for: nil), 45, accuracy: 1e-9)
            fanControl.setManualFansSynchronized(false)
            XCTAssertEqual(fanControl.manualPercentage(for: 0), 20, accuracy: 1e-9, "the shared step leaves the fans' values")
            XCTAssertEqual(fanControl.manualPercentage(for: 1), 80, accuracy: 1e-9)
            XCTAssertEqual(fanControl.selectedMode, .systemAutomatic)
            XCTAssertNil(fanControl.requestedMode)
        }
    }

    /// D152: the modes are text sections with iStat's switch on the major
    /// label and Sync is a tick row (were FanControlModeCard with a round
    /// FanControlModeSelectionMark, a selection that edited the draft until
    /// Apply, and FanSyncToggleRow's 双风扇同步 capsule switch).
    func testPaletteUsesCardsForModesAndKeepsTheSwitchForFanSync() throws {
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        let shared = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/FanControlInlineControls.swift")
        XCTAssertFalse(palette.contains("FanControlModeCard("))
        XCTAssertFalse(palette.contains("FanControlModeSelectionMark"))
        XCTAssertFalse(palette.contains("ControlPaletteModeRow"))
        let view = try r2SourceDeclaration("struct FanControlPaletteView: View", in: palette)
        XCTAssertTrue(view.contains("GeekIStatTextSectionCard {\n            GeekIStatMajorLabelRow(title: choice.title, hasRowsBelow: choice == .manual) {"))
        XCTAssertTrue(view.contains(".toggleStyle(GeekIStatSwitchToggleStyle())"))
        XCTAssertTrue(view.contains("GeekIStatTickRow(\n                    title: L10n.text(\"同步\", \"Sync\"),"))
        XCTAssertFalse(view.contains("Capsule("))
        // A switch chooses at once; the one that is on does nothing.
        XCTAssertFalse(palette.contains("draft.selectMode(mode)"))
        XCTAssertTrue(view.contains("set: { isOn in if isOn { choose(choice.mode) } }"))
        XCTAssertTrue(view.contains("guard mode != displayedMode, disabledReason(mode) == nil else { return }"))
        XCTAssertFalse(shared.contains("FanSyncToggleRow"))
        XCTAssertFalse(shared.contains("双风扇同步"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

/// Override only this test process's volatile argument domain; the real
/// app's saved language preference is never changed.
@MainActor
private final class FanCardLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

@MainActor
private final class FanCardFrameRecorder {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class ChargeSegmentTestCalls {
    var targets: [BatteryChargeTarget] = []
    var fullCharge = 0
}

/// Hosts a view in a borderless window and drives it through the native
/// accessibility tree, as VoiceOver does (same approach as
/// `SafeCleanupScopeCardLayoutTests`).
@MainActor
private final class FanCardAccessibilityFixture<Root: View> {
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow

    init(root: Root, height: CGFloat = 120) {
        _ = NSApplication.shared
        // SwiftUI builds the accessibility tree of its own controls (the
        // charge-limit segments, D149; D124's tick rows) only for an
        // assistive client. Enable the public environment for this inert
        // host, as CalibrationAppKitLayoutHost does; no macOS preference
        // changes, and the tree and actions still come from SwiftUI.
        controller = NSHostingController(rootView: AnyView(root.environment(\.accessibilityEnabled, true)))
        controller.sizingOptions = []
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 260, height: height))
    }

    func button(label: String, role: String? = NSAccessibility.Role.button.rawValue) async throws -> NSObject {
        for _ in 0..<100 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let match = find(label: label, role: role) { return match }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FanControlModeCardTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No native button labelled \(label): \(snapshot())",
        ])
    }

    /// D124: the element's enabled state through the accessibility protocol
    /// (the charge-limit rows; was the segmented picker's finder).
    func isEnabled(_ element: NSObject) throws -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard element.responds(to: selector) else { return nil }
        typealias NativeFlag = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(element.method(for: selector))
        return unsafeBitCast(implementation, to: NativeFlag.self)(element, selector)
    }

    func contains(label: String) -> Bool { find(label: label, role: nil) != nil }

    /// D152: whether an element shows this text as its label, title or value
    /// (a static text exposes its string as the value).
    func contains(text: String) -> Bool { find(text: text) != nil }

    /// D152: a numeric attribute, such as a native toggle's 1 or 0.
    func number(_ object: NSObject, _ selector: String) -> Int? {
        (objectValue(object, selector) as? NSNumber)?.intValue
    }

    /// D152: the element with this accessibility identifier, whatever its
    /// role (a section's switch, a slider, the Sync row).
    func element(identifier: String) async throws -> NSObject {
        for _ in 0..<100 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let match = find(identifier: identifier) { return match }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FanControlModeCardTests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "No native element \(identifier): \(snapshot())",
        ])
    }

    func savePNG(to url: URL) throws {
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func press(_ element: NSObject) throws -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias NativePress = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(element.method(for: selector))
        return unsafeBitCast(implementation, to: NativePress.self)(element, selector)
    }

    /// D152: another native action by its selector, such as a slider's
    /// accessibilityPerformIncrement; false when the element lacks it.
    func perform(_ selectorName: String, on element: NSObject) throws -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard element.responds(to: selector) else { return false }
        typealias NativeAction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(element.method(for: selector))
        return unsafeBitCast(implementation, to: NativeAction.self)(element, selector)
    }

    func text(_ object: NSObject, _ selector: String) -> String? {
        let value = objectValue(object, selector)
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return nil
    }

    /// SwiftUI publishes accessibility on a later main-actor turn; detaching
    /// the host synchronously makes SDK 27's render state machine throw
    /// InvalidTransition(failed(deinit)) into the next test. Hide the window
    /// now and detach after those turns, as CalibrationAppKitLayoutHost does.
    func close() {
        window.orderOut(nil)
        Task { @MainActor [window, controller] in
            await Task.yield()
            window.contentViewController = nil
            window.close()
            _ = controller
        }
    }

    func syncFrame(from recorder: FanCardFrameRecorder) async throws -> CGRect {
        var last: CGRect?
        var stable = 0
        for _ in 0..<100 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            // D152: the Sync tick row's probe (was the switch's "fan.sync.toggle").
            if let frame = recorder.frames["fan.manual.sync"] {
                stable = frame == last ? stable + 1 : 0
                last = frame
                if stable >= 2 { return frame }
            }
        }
        throw NSError(domain: "FanControlModeCardTests", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Sync row frame did not stabilize"])
    }

    private func find(label: String, role: String?) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ element: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            if text(element, "accessibilityLabel") == label || text(element, "accessibilityTitle") == label,
               (role == nil || text(element, "accessibilityRole") == role) {
                return element
            }
            for child in children(element) {
                if let match = search(child) { return match }
            }
            return nil
        }
        return search(controller.view) ?? search(window)
    }

    private func find(text value: String) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ element: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            let shown = [text(element, "accessibilityLabel"), text(element, "accessibilityTitle"),
                         text(element, "accessibilityValue")]
            if shown.contains(value) { return element }
            for child in children(element) {
                if let match = search(child) { return match }
            }
            return nil
        }
        return search(controller.view) ?? search(window)
    }

    private func find(identifier: String) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ element: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            if text(element, "accessibilityIdentifier") == identifier { return element }
            for child in children(element) {
                if let match = search(child) { return match }
            }
            return nil
        }
        return search(controller.view) ?? search(window)
    }

    private func children(_ object: NSObject) -> [NSObject] {
        (objectValue(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
    }

    private func objectValue(_ object: NSObject, _ selector: String) -> AnyObject? {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func snapshot() -> [String] {
        var rows = [String]()
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted, rows.count < 60 else { return }
            rows.append("\(type(of: object)) role=\(text(object, "accessibilityRole") ?? "nil") label=\(text(object, "accessibilityLabel") ?? "nil")")
            children(object).forEach(collect)
        }
        collect(controller.view)
        return rows
    }
}

@MainActor
private final class FanCardHost<Root: View> {
    private let host: NSHostingView<Root>
    private let window: NSWindow

    init(root: Root, size: CGSize) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func frames(from recorder: FanCardFrameRecorder, required: Set<String>) async throws -> [String: CGRect] {
        var lastFrames: [String: CGRect]?
        var stable = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if required.isSubset(of: Set(recorder.frames.keys)) {
                let current = recorder.frames.filter { required.contains($0.key) }
                if current == lastFrames { stable += 1 } else { stable = 0 }
                lastFrames = current
                if stable >= 2 { return current }
            }
        }
        throw NSError(domain: "FanControlModeCardTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native layout frames did not stabilize"])
    }

    /// As the accessibility fixture does: hide now and detach after SwiftUI's
    /// pending main-actor turns. A synchronous detach makes SDK 27's render
    /// state machine throw InvalidTransition(failed(deinit)) into a later
    /// test (D152: testOverviewEntry… after the palette layouts; was
    /// `window.contentView = nil` at once).
    func close() {
        window.orderOut(nil)
        Task { @MainActor [window, host] in
            await Task.yield()
            window.contentView = nil
            window.close()
            _ = host
        }
    }
}
#endif
