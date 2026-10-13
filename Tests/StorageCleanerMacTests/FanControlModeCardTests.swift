#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// UI plan U1 117/118 and docs/mini-window-design.md "风扇控制": the four
/// exclusive fan modes are vertical single-choice cards — icon, title,
/// a round selection mark on the right. D64 moves subtitle copy to AX hints. A switch is only used
/// for synchronising the fans. Only the views are rendered here: no fan
/// coordinator, helper or hardware call is involved.
@MainActor
final class FanControlModeCardTests: XCTestCase {
    func testPaletteOffersFourSingleChoiceModesWithIconTitleAndSubtitle() {
        XCTAssertEqual(FanControlModeChoice.allCases.map(\.mode), [.systemAutomatic, .customCurve, .manual, .maximum])
        XCTAssertEqual(FanControlModeChoice(mode: .systemAutomatic), .automatic)
        XCTAssertEqual(FanControlModeChoice(mode: .customCurve), .curve)
        XCTAssertEqual(FanControlModeChoice(mode: .manual), .manual)
        XCTAssertEqual(FanControlModeChoice(mode: .maximum), .maximum)
        XCTAssertEqual(FanControlModeChoice.maximum.title, GeekFanControlMode.maximum.title)
        XCTAssertEqual(FanControlModeChoice.maximum.subtitle, L10n.text("所有风扇使用硬件最大转速", "Use the hardware maximum RPM for every fan"))
        XCTAssertNil(FanControlModeChoice(mode: .fanSet))

        XCTAssertEqual(FanControlModeChoice.automatic.title, L10n.text("自动控制", "Automatic"))
        XCTAssertEqual(FanControlModeChoice.automatic.subtitle, L10n.text("交给 macOS 动态调节", "macOS adjusts the fans"))
        XCTAssertEqual(FanControlModeChoice.curve.title, L10n.text("自定义风扇曲线", "Custom Fan Curve"))
        XCTAssertEqual(FanControlModeChoice.curve.subtitle, L10n.text("按温度曲线调节转速", "Follows a temperature curve"))
        XCTAssertEqual(FanControlModeChoice.manual.title, L10n.text("手动控制", "Manual"))
        XCTAssertEqual(FanControlModeChoice.manual.subtitle, L10n.text("直接设置目标转速", "Set a target speed directly"))
        XCTAssertEqual(FanControlModeChoice.automatic.systemImage, AppSymbols.Monitor.sensors)
        XCTAssertEqual(FanControlModeChoice.curve.systemImage, AppSymbols.Monitor.advanced)
        XCTAssertEqual(FanControlModeChoice.manual.systemImage, AppSymbols.Panel.settings)
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

    func testPaletteModesStayVisibleButSetupBlocksSelectionAndManualShowsApply() async throws {
        for state: MiniWindowDemoData.HardwareControlDemoState in [.fanAutomatic, .fanManual65, .fanMaximum, .helperNotRegistered,
                .awaitingSystemApproval, .connectionInterrupted, .helperUntrusted, .helperUnavailable] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let snapshot = MiniWindowDemoData.fixture.snapshot
            let fanControl = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile, snapshot: snapshot)
            let presentation = ControlPalettePresentationState()
            presentation.present(.fan)
            let view = FanControlPaletteView(presentation: presentation, fanControl: fanControl,
                telemetry: MiniWindowDemoData.fanTelemetry(for: state), thermalState: .nominal)
                .frame(width: 280)
                .environment(\.accessibilityEnabled, true)
            let fixture = FanCardAccessibilityFixture(root: view, height: 560)
            defer { fixture.close() }
            for choice in FanControlModeChoice.allCases {
                let button = try await fixture.button(label: choice.title)
                if profile.helperState != .enabled {
                    XCTAssertEqual(fixture.text(button, "accessibilityHelp"), FanControlSetupPresentation.reason(profile.helperState))
                    _ = try fixture.press(button)
                }
            }
            if profile.helperState != .enabled {
                XCTAssertTrue(fixture.contains(label: FanControlSetupPresentation.capsuleTitle(profile.helperState)),
                    "The status capsule must describe setup, not show a dash")
            }
            if profile.helperState == .enabled {
                let manual = try await fixture.button(label: FanControlModeChoice.manual.title)
                XCTAssertTrue(try fixture.press(manual))
                _ = try await fixture.button(label: L10n.text("应用", "Apply"))
                _ = try await fixture.button(label: L10n.text("风扇转速", "Fan Speed"), role: nil)
                let manualReadback = try await fixture.button(label: FanControlModeChoice.manual.title)
                XCTAssertEqual(fixture.text(manualReadback, "accessibilityValue"), L10n.text("已选择", "Selected"))
                let maximum = try await fixture.button(label: FanControlModeChoice.maximum.title)
                XCTAssertTrue(try fixture.press(maximum))
                let selectedMaximum = try await fixture.button(label: FanControlModeChoice.maximum.title)
                XCTAssertEqual(fixture.text(selectedMaximum, "accessibilityValue"), L10n.text("已选择", "Selected"))
                let curve = try await fixture.button(label: FanControlModeChoice.curve.title)
                XCTAssertTrue(try fixture.press(curve))
                let editor = try await fixture.button(label: L10n.text("编辑曲线", "Edit Curve"))
                XCTAssertTrue(try fixture.press(editor))
                for _ in 0..<50 where presentation.fanPage != .curveEditor {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(presentation.fanPage, .curveEditor)
            } else {
                try await Task.sleep(for: .milliseconds(50))
                for choice in FanControlModeChoice.allCases {
                    let button = try await fixture.button(label: choice.title)
                    XCTAssertEqual(fixture.text(button, "accessibilityValue"), L10n.text("未选择", "Not Selected"))
                }
                _ = try await fixture.button(label: FanControlSetupPresentation.actionTitle(profile.helperState))
            }
            XCTAssertNil(fanControl.requestedMode, "Preview and disabled controls must never send a write")
            XCTAssertEqual(fanControl.observedMode, profile.observedMode)
        }
    }

    func testChargeSegmentsUseEffectiveReadbackAndDoNotHighlightUnconfirmedWrites() async throws {
        let targets = [80, 90, 100].compactMap(BatteryChargeTarget.init(rawValue:))
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
                .frame(width: 280)
            let fixture = FanCardAccessibilityFixture(root: view, height: 240)
            defer { fixture.close() }
            let segments = try await fixture.segmentedControl()
            let expected = targets.firstIndex { $0.rawValue == effective } ?? -1
            XCTAssertEqual(segments.selectedSegment, expected, "Only the actual limit may be selected")
            XCTAssertEqual(segments.segmentCount, 3)
            XCTAssertEqual((0..<segments.segmentCount).map { segments.label(forSegment: $0) }, ["80%", "90%", "100%"])
            segments.selectedSegment = 1
            XCTAssertTrue(segments.sendAction(segments.action, to: segments.target))
            for _ in 0..<50 where calls.targets.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(calls.targets, [targets[1]])
            XCTAssertEqual(calls.fullCharge, 0, "A segment must never request temporary full charge")
            // The closure reports applied, but the supplied system reading has not changed.
            // A new layout must return the highlight to that reading rather than the request.
            let readback = try await fixture.segmentedControl()
            XCTAssertEqual(readback.selectedSegment, expected)
        }
    }

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
                    .frame(width: 280).environment(\.colorScheme, dark ? .dark : .light)
                let fixture = FanCardAccessibilityFixture(root: view, height: 200)
                defer { fixture.close() }
                let segments = try await fixture.segmentedControl()
                XCTAssertEqual(segments.isEnabled, writable)
                XCTAssertEqual(segments.selectedSegment, 0)
                XCTAssertEqual(segments.label(forSegment: 0), "80%")
                XCTAssertEqual(segments.label(forSegment: 1), "100%")
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
                        let fanControl = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile,
                            snapshot: MiniWindowDemoData.makeFixture(arguments: [MiniWindowDemoData.hardwareControlStateArgumentPrefix + state.rawValue]).snapshot)
                        fanControl.setManualFansSynchronized(synchronized)
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
                    let frames = try await host.frames(from: recorder, required: ["overview.sensor.card", "overview.sensor.header", "overview.sensor.entry", "overview.sensor.cpu"])
                    let card = try XCTUnwrap(frames["overview.sensor.card"])
                    let header = try XCTUnwrap(frames["overview.sensor.header"])
                    let row = try XCTUnwrap(frames["overview.sensor.entry"])
                    let ring = try XCTUnwrap(frames["overview.sensor.cpu"])
                    XCTAssertEqual(card.height, GeekPanelLayout.overviewSensorsCardHeight, accuracy: 0.5)
                    XCTAssertEqual(row.height, FanControlEntryRow.headerHeight, accuracy: 0.5)
                    XCTAssertEqual(FanControlEntryRow.height, 24, "Secondary-page rows retain their original hit area")
                    XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(row))
                    // fix2 replaces the full-width bottom row with the title's
                    // trailing button. Both insets remain owned by the same card.
                    XCTAssertEqual(header.minX, card.minX + GeekVisualTokens.cardHorizontalPadding, accuracy: 0.5)
                    XCTAssertEqual(row.maxX, card.maxX - GeekVisualTokens.cardHorizontalPadding, accuracy: 0.5)
                    XCTAssertTrue(header.insetBy(dx: -0.5, dy: -0.5).contains(row))
                    XCTAssertEqual(row.midY, header.midY, accuracy: 0.5)
                    XCTAssertLessThanOrEqual(header.maxY, ring.minY - 4 + 0.5)
                    let titleWidth = (L10n.text("传感器", "Sensors") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
                    XCTAssertGreaterThanOrEqual(row.minX - header.minX, titleWidth + MiniWindowStyleTokens.moduleIconSlotSize
                        + MiniWindowStyleTokens.moduleIconSpacing + MiniWindowStyleTokens.inlineSpacing - 0.5,
                        "The full Sensors heading must keep its original width")
                    let labelWidth = ((L10n.text("风扇控制", "Fan Control") + " · " + entry.headerStatus) as NSString)
                        .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
                    XCTAssertLessThanOrEqual(labelWidth * 0.75, row.width - MiniWindowStyleTokens.disclosureIconSlotSize - 4,
                        "The complete title-row entry must fit for \(state) in \(language)")
                }
            }
        }
    }

    func testModeCardDrawsARoundSelectionMarkOnTheRight() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = FanCardLanguageScope(language)
            defer { languageScope.restore() }
            for choice in FanControlModeChoice.allCases {
                for selected in [true, false] {
                    let recorder = FanCardFrameRecorder()
                    let root = VStack(spacing: 0) {
                        FanControlModeCard(
                            choice: choice, selected: selected, isApplying: false, isDisabled: false,
                            action: { XCTFail("Layout inspection must not choose a fan mode") }
                        )
                    }
                    .frame(width: 248)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in recorder.frames = frames }
                    }
                    let host = FanCardHost(root: root, size: CGSize(width: 260, height: 160))
                    defer { host.close() }
                    let frames = try await host.frames(
                        from: recorder,
                        required: ["fan.mode.card", "fan.mode.icon", "fan.mode.title", "fan.mode.mark"]
                    )
                    let tag = "\(choice) selected=\(selected) \(language)"
                    let card = try XCTUnwrap(frames["fan.mode.card"])
                    let icon = try XCTUnwrap(frames["fan.mode.icon"])
                    let title = try XCTUnwrap(frames["fan.mode.title"])
                    XCTAssertNil(recorder.frames["fan.mode.subtitle"], "D64 removes visible option explanations")
                    let mark = try XCTUnwrap(frames["fan.mode.mark"])

                    // A round mark, not the old 32 × 18 switch capsule.
                    XCTAssertEqual(mark.width, 16, accuracy: 0.5, tag)
                    XCTAssertEqual(mark.height, 16, accuracy: 0.5, tag)
                    XCTAssertEqual(mark.maxX, card.maxX - 8, accuracy: 1, "Mark sits on the right: \(tag)")
                    XCTAssertEqual(mark.midY, card.midY, accuracy: 1, tag)
                    // D64: icon and title remain aligned in the single row.
                    XCTAssertEqual(icon.minX, card.minX + 8, accuracy: 1, tag)
                    XCTAssertGreaterThanOrEqual(title.minX, icon.maxX, tag)
                    XCTAssertEqual(title.midY, icon.midY, accuracy: 1, tag)
                    XCTAssertLessThanOrEqual(icon.maxX, title.minX, tag)
                    XCTAssertLessThanOrEqual(title.maxX, mark.minX, tag)
                    // The whole card is the click target and is taller than the old 27 pt row.
                    XCTAssertGreaterThanOrEqual(card.height, 35.5, tag)
                    XCTAssertEqual(card.width, 248, accuracy: 0.5, tag)
                    XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(title), tag)
                }
            }
        }
    }

    /// Review P1-2: the card is one native accessibility button. A VoiceOver
    /// press (AXPress) runs the selection callback, and the element still
    /// reads the title, the subtitle as its hint and whether it is selected.
    func testVoiceOverPressChoosesTheMode() async throws {
        for selected in [false, true] {
            let counter = FanCardPressCounter()
            let card = FanControlModeCard(
                choice: .manual, selected: selected, isApplying: false, isDisabled: false,
                action: { counter.presses += 1 }
            )
            .frame(width: 248)
            .fixedSize(horizontal: false, vertical: true)
            // SwiftUI builds its native accessibility tree only when asked to.
            .environment(\.accessibilityEnabled, true)
            let fixture = FanCardAccessibilityFixture(root: card)
            defer { fixture.close() }
            let element = try await fixture.button(label: FanControlModeChoice.manual.title)
            XCTAssertEqual(fixture.text(element, "accessibilityHelp"), FanControlModeChoice.manual.subtitle)
            XCTAssertEqual(
                fixture.text(element, "accessibilityValue"),
                selected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not Selected")
            )
            XCTAssertTrue(try fixture.press(element), "AXPress must be handled (selected=\(selected))")
            for _ in 0..<50 where counter.presses == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(counter.presses, 1, "A VoiceOver press must choose the mode (selected=\(selected))")
        }
    }

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
                let state = FanSyncTestDraft(telemetry: telemetry)
                let recorder = FanCardFrameRecorder()
                let root = FanSyncTestControls(state: state, telemetry: telemetry, disabled: disabled)
                    .frame(width: 248)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.accessibilityEnabled, true)
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in recorder.frames = frames }
                    }
                let fixture = FanCardAccessibilityFixture(root: root)
                defer { fixture.close() }
                let label = L10n.text("同步所有风扇", "Synchronize All Fans")
                let button = try await fixture.button(label: label)
                XCTAssertEqual(fixture.text(button, "accessibilityValue"), L10n.text("已开启", "On"))
                let original = try await fixture.syncFrame(from: recorder)
                XCTAssertGreaterThanOrEqual(original.height, 24 - 0.5, "Preserve the switch's click height")
                let pressed = try fixture.press(button)
                if disabled {
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertTrue(state.draft.synchronizesFans, "Disabled AXPress must not edit the draft")
                } else {
                    XCTAssertTrue(pressed)
                    for _ in 0..<100 where state.draft.synchronizesFans {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertFalse(state.draft.synchronizesFans)
                    let offButton = try await fixture.button(label: label)
                    XCTAssertEqual(fixture.text(offButton, "accessibilityValue"), L10n.text("已关闭", "Off"))
                    let unsynchronized = try await fixture.syncFrame(from: recorder)
                    XCTAssertEqual(unsynchronized.minY, original.minY, accuracy: 0.5,
                        "Showing Target Fan must not shift the switch down a row")
                    XCTAssertEqual(unsynchronized.height, original.height, accuracy: 0.5)
                    XCTAssertEqual(unsynchronized.maxX, original.maxX, accuracy: 0.5,
                        "The switch sits at the row's trailing edge; Target Fan must not push it sideways")
                    XCTAssertTrue(try fixture.press(offButton))
                    for _ in 0..<100 where !state.draft.synchronizesFans {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(state.draft.synchronizesFans)
                    let synchronized = try await fixture.syncFrame(from: recorder)
                    XCTAssertEqual(synchronized.minY, original.minY, accuracy: 0.5)
                    XCTAssertEqual(synchronized.maxX, original.maxX, accuracy: 0.5)
                }
                XCTAssertEqual(state.draft.mode, .manual, "AXPress changes only the local sync draft")
            }
        }
    }

    func testPaletteUsesCardsForModesAndKeepsTheSwitchForFanSync() throws {
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        let shared = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/FanControlInlineControls.swift")
        XCTAssertTrue(palette.contains("FanControlModeCard("))
        XCTAssertFalse(palette.contains("ControlPaletteModeRow"))
        // The mode cards no longer draw a switch capsule. Only the card and its
        // mark are checked; other views in the file may use capsules (P2-6).
        let card = try r2SourceDeclaration("struct FanControlModeCard: View", in: palette)
        let mark = try r2SourceDeclaration("struct FanControlModeSelectionMark: View", in: palette)
        XCTAssertTrue(card.contains("FanControlModeSelectionMark("))
        XCTAssertFalse(card.contains(".frame(width: 32, height: 18)"))
        XCTAssertFalse(card.contains("Capsule("))
        XCTAssertTrue(mark.contains("Circle()"))
        // Selection still only edits the draft; Apply submits.
        XCTAssertTrue(palette.contains("draft.selectMode(mode)"))
        // The only switch left is "sync both fans".
        let sync = try r2SourceDeclaration("struct FanSyncToggleRow: View", in: shared)
        XCTAssertTrue(sync.contains("Capsule(style: .continuous)"))
        XCTAssertTrue(sync.contains("双风扇同步"))
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

@MainActor
private final class FanSyncTestDraft: ObservableObject {
    @Published var draft: FanControlDraft
    init(telemetry: FanTelemetryState) {
        draft = FanControlDraft(telemetry: telemetry, observedMode: .manual, synchronizesFans: true)
    }
}

@MainActor
private struct FanSyncTestControls: View {
    @ObservedObject var state: FanSyncTestDraft
    let telemetry: FanTelemetryState
    let disabled: Bool
    var body: some View {
        FanManualSliderList(draft: $state.draft, telemetry: telemetry, isDisabled: disabled, compact: true)
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

@MainActor
private final class FanCardPressCounter {
    var presses = 0
}

/// Hosts a view in a borderless window and drives it through the native
/// accessibility tree, as VoiceOver does (same approach as
/// `SafeCleanupScopeCardLayoutTests`).
@MainActor
private final class FanCardAccessibilityFixture<Root: View> {
    private let controller: NSHostingController<Root>
    private let window: NSWindow

    init(root: Root, height: CGFloat = 120) {
        _ = NSApplication.shared
        controller = NSHostingController(rootView: root)
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

    func segmentedControl() async throws -> NSSegmentedControl {
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<100 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let control = find(controller.view) { return control }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FanControlModeCardTests", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "No native segmented charge-limit picker"])
    }

    func contains(label: String) -> Bool { find(label: label, role: nil) != nil }

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

    func text(_ object: NSObject, _ selector: String) -> String? {
        let value = objectValue(object, selector)
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return nil
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    func syncFrame(from recorder: FanCardFrameRecorder) async throws -> CGRect {
        var last: CGRect?
        var stable = 0
        for _ in 0..<100 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if let frame = recorder.frames["fan.sync.toggle"] {
                stable = frame == last ? stable + 1 : 0
                last = frame
                if stable >= 2 { return frame }
            }
        }
        throw NSError(domain: "FanControlModeCardTests", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Sync switch frame did not stabilize"])
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

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
