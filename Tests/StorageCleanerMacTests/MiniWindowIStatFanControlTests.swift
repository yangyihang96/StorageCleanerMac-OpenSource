#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D152: iStat Menus 7.30's fan submenu (`-[SensorsMenu loadItems]`,
/// `BBRSensorsManualFanItem`, `BBRSensorsMenuFanSlider`) as the fan palette
/// draws it: a 200 pt page of text sections (Automatic, Custom Fan Curve,
/// Manual with Sync and the sliders, our Maximum), the slider's geometry
/// and gestures, and iStat's semantics in the coordinator: the slider
/// values are settings that persist, Sync only picks the shared or the
/// per-fan sliders, one fan always takes the shared one. Renders the
/// production palette offscreen with coordinators whose transport fails the
/// test or answers locally: no helper, hardware write, window or user data.
@MainActor
final class MiniWindowIStatFanControlTests: XCTestCase {
    private static let cardWidth = ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding
    private static let cpu = SystemFanReading(index: 0, identity: .cpu, actualRPM: 2_000,
                                              minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil)
    private static let gpu = SystemFanReading(index: 1, identity: .gpu, actualRPM: 3_000,
                                              minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil)

    /// `-[BBRSensorsMenuFanSlider drawRect:]`, `mouseDown:` and
    /// `mouseDragged:` in a 184 pt card: the track 8 in from each side, a
    /// press between 8 and W − 8 sets the value, a drag takes the whole-point
    /// x clamped to [8, (int)(W − 8)], the value reads '%.0f%%', the sliders
    /// are 30 tall and 8 apart, and a drag writes 0.2 s after it stops.
    func testTheSliderHasIStatsGeometry() {
        typealias Geometry = FanControlSliderGeometry
        XCTAssertEqual([Geometry.height, Geometry.spacing, Geometry.inset], [30, 8, 8])
        XCTAssertEqual([Geometry.labelTop, Geometry.labelHeight, Geometry.valueTrailing], [-3, 15, 10])
        XCTAssertEqual([Geometry.trackTop, Geometry.trackHeight, Geometry.trackRadius], [18, 8, 4])
        XCTAssertEqual([Geometry.knobSize, Geometry.knobTop, Geometry.knobHitTop], [16, 14, 17])
        XCTAssertEqual(FanControlSafetyPolicy.manualControlDebounce, 0.2, "iStat writes 0.2 s after the last drag")
        let width = Self.cardWidth
        XCTAssertEqual(width, 184)
        XCTAssertEqual(Geometry.trackWidth(width), 168)
        XCTAssertEqual(Geometry.knobLeading(fraction: 0.5, width: width), 84)
        XCTAssertEqual(Geometry.knobLeading(fraction: 2, width: width), 168, "the knob stops at the track's end")
        XCTAssertEqual(Geometry.knobHitRect(fraction: 0.25, width: width), CGRect(x: 42, y: 17, width: 16, height: 16))
        XCTAssertEqual(Geometry.fraction(pressAt: 8, width: width), 0)
        XCTAssertEqual(Geometry.fraction(pressAt: 92, width: width), 0.5)
        XCTAssertEqual(Geometry.fraction(pressAt: 176, width: width), 1)
        XCTAssertNil(Geometry.fraction(pressAt: 7.5, width: width), "a press left of the track does nothing")
        XCTAssertNil(Geometry.fraction(pressAt: 176.5, width: width), "a press right of the track does nothing")
        XCTAssertEqual(Geometry.fraction(dragAt: -40, width: width), 0)
        XCTAssertEqual(Geometry.fraction(dragAt: 92.9, width: width), 0.5, "the whole point")
        XCTAssertEqual(Geometry.fraction(dragAt: 400, width: width), 1)
        XCTAssertEqual(Geometry.fraction(dragAt: 400, width: 183.5), (175 - 8) / 167.5, accuracy: 1e-9,
                       "the upper bound is (int)(W − 8)")
        XCTAssertNil(Geometry.fraction(pressAt: 8, width: 16), "no track, no value")
        XCTAssertEqual(Geometry.fraction(dragAt: 10, width: 16), 0)
        XCTAssertEqual(Geometry.valueText(fraction: 0.654), "65%")
        XCTAssertEqual(Geometry.valueText(fraction: 0), "0%")
        XCTAssertEqual(Geometry.valueText(fraction: 1.4), "100%")
        XCTAssertEqual(Geometry.valueText(fraction: -0.2), "0%")
        XCTAssertEqual(Geometry.valueText(fraction: .nan), "0%")
        XCTAssertEqual((0...3).map(Geometry.listHeight(count:)), [0, 30, 68, 106])
    }

    /// `mouseDown:`, `mouseDragged:` and `mouseUp:` over a 184 pt slider: a
    /// press on the knob (its 16 pt hit box at (p × 168, 17), 3 below the
    /// drawn knob) writes nothing and the drag stores; a press beside it on
    /// the track writes at once; a press outside the track makes the rest of
    /// the gesture do nothing; the release writes what the gesture holds and
    /// the next gesture starts afresh.
    func testTheSliderTracksTheMouseAsIStat() {
        typealias Tracking = FanControlSliderGeometry.Tracking
        let width = Self.cardWidth
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
        var tracking = Tracking()
        // On the knob at 25 % (x 42 … 58).
        XCTAssertEqual(tracking.changed(start: point(50, 25), location: point(50, 25), width: width, stored: 0.25), [])
        XCTAssertEqual(tracking.fraction, 0.25)
        XCTAssertEqual(tracking.changed(start: point(50, 25), location: point(92.9, 25), width: width, stored: 0.25),
                       [.drag(0.5)], "the drag takes the whole point")
        XCTAssertEqual(tracking.ended(), [.commit(0.5)])
        XCTAssertEqual(tracking, Tracking())
        XCTAssertEqual(tracking.changed(start: point(50, 25), location: point(50, 25), width: width, stored: 0.25), [])
        XCTAssertEqual(tracking.ended(), [.commit(0.25)], "the release writes even without a move")
        // Beside the knob at 50 % (x 84 … 100, y 17 … 33).
        XCTAssertEqual(tracking.changed(start: point(50, 10), location: point(50, 10), width: width, stored: 0.5),
                       [.commit(0.25)])
        XCTAssertEqual(tracking.changed(start: point(50, 10), location: point(176, 10), width: width, stored: 0.25),
                       [.drag(1)])
        XCTAssertEqual(tracking.ended(), [.commit(1)])
        XCTAssertEqual(tracking.changed(start: point(90, 15), location: point(90, 15), width: width, stored: 0.5),
                       [.commit((90 - 8) / 168.0)], "above the hit box counts as beside the knob")
        _ = tracking.ended()
        XCTAssertEqual(tracking.changed(start: point(50, 10), location: point(60.4, 10), width: width, stored: 0.5),
                       [.commit(0.25), .drag((60 - 8) / 168.0)], "a press that has already moved writes, then drags")
        _ = tracking.ended()
        // Past the ends while dragging the knob; each step passes the value
        // the coordinator stored from the last one.
        XCTAssertEqual(tracking.changed(start: point(92, 25), location: point(-40, 25), width: width, stored: 0.5),
                       [.drag(0)])
        XCTAssertEqual(tracking.changed(start: point(92, 25), location: point(400, 25), width: width, stored: 0),
                       [.drag(1)])
        XCTAssertEqual(tracking.ended(), [.commit(1)])
        // Outside the track: nothing until the release, then afresh.
        for x: CGFloat in [4, 176.5] {
            XCTAssertEqual(tracking.changed(start: point(x, 25), location: point(x, 25), width: width, stored: 0.5), [])
            XCTAssertTrue(tracking.isIgnored)
            XCTAssertEqual(tracking.changed(start: point(x, 25), location: point(100, 25), width: width, stored: 0.5), [])
            XCTAssertEqual(tracking.ended(), [])
            XCTAssertEqual(tracking, Tracking())
        }
        // The press decides once: a value stored meanwhile that brings the
        // knob under it (0 % puts the hit box at x 0 … 16) changes nothing.
        XCTAssertEqual(tracking.changed(start: point(4, 25), location: point(4, 25), width: width, stored: 0.5), [])
        XCTAssertEqual(tracking.changed(start: point(4, 25), location: point(100, 25), width: width, stored: 0), [])
        XCTAssertEqual(tracking.ended(), [])
    }

    /// `-[BBRSensorsManualFanItem update]`: one slider labelled Fans while
    /// synchronized and always with one fan, otherwise one per fan under its
    /// name; the planner refuses a fan listed twice or without a range, so
    /// no slider is offered for one.
    func testTheSlidersFollowTheFansAndSync() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let fans = language == .english ? "Fans" : "风扇"
            typealias List = FanManualSliderList
            XCTAssertEqual(List.sliders(readings: [Self.cpu, Self.gpu], synchronizes: true),
                           [.init(fanID: nil, title: fans)])
            XCTAssertEqual(List.sliders(readings: [Self.cpu, Self.gpu], synchronizes: false),
                           [.init(fanID: 0, title: Self.cpu.displayName), .init(fanID: 1, title: Self.gpu.displayName)])
            XCTAssertEqual(List.sliders(readings: [Self.gpu], synchronizes: false), [.init(fanID: nil, title: fans)],
                           "one fan always takes the shared slider")
            XCTAssertEqual(List.sliders(readings: [], synchronizes: true), [])
            XCTAssertEqual(List.sliders(readings: [Self.cpu, Self.cpu], synchronizes: false), [],
                           "a fan listed twice has no slider")
            XCTAssertEqual(List.sliders(readings: [Self.cpu, Self.gpu], synchronizes: false).map(\.id), [0, 1])
            XCTAssertEqual(List.sliders(readings: [Self.cpu], synchronizes: true).map(\.id), [-1])
        }
        let resolve = { (fans: [SystemFanReading]) in FanTelemetryState.resolve(snapshot: Self.snapshot(fans: fans)) }
        XCTAssertTrue(FanManualSliderList.isAvailable(for: resolve([Self.cpu, Self.gpu])))
        XCTAssertFalse(FanManualSliderList.isAvailable(for: resolve([Self.cpu, Self.cpu])))
        XCTAssertFalse(FanManualSliderList.isAvailable(for: resolve([Self.cpu, SystemFanReading(
            index: 1, actualRPM: 3_000, minimumRPM: nil, maximumRPM: nil, targetRPM: nil)])))
    }

    /// iStat's section titles in its order with our Maximum last; one switch
    /// is on: the mode being set up, else the coordinator's (a fixed fan set
    /// from Settings shows as manual); a fanless Mac has none.
    func testTheModesAreIStatsSectionsInIStatsOrder() {
        for (language, titles) in [(AppLanguage.zhHans, ["自动", "自定义风扇曲线", "手动", "最大转速"]),
                                   (.english, ["Automatic", "Custom Fan Curve", "Manual", "Maximum RPM"])] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(FanControlModeChoice.allCases.map(\.title), titles)
            XCTAssertEqual(FanControlPaletteView.previewNote,
                           language == .english ? "Preview · Fan Controls Disabled" : "模拟预览 · 不会更改风扇",
                           "the preview note follows the language")
        }
        let telemetry = FanTelemetryState.resolve(snapshot: Self.snapshot(fans: [Self.cpu]))
        XCTAssertEqual(FanControlPaletteAvailability.visibleModes(telemetry: telemetry),
                       [.systemAutomatic, .customCurve, .manual, .maximum])
        let fanless = FanTelemetryState(actualRPM: nil, minRPM: nil, maxRPM: nil, targetRPM: nil, fanCount: 0,
            timestamp: nil, telemetryAvailable: false, isSampling: false, isFanless: true, readings: [])
        XCTAssertEqual(FanControlPaletteAvailability.visibleModes(telemetry: fanless), [])
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: nil, selected: .customCurve), .customCurve)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: .maximum, selected: .systemAutomatic), .maximum)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: nil, selected: .fanSet), .manual)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: .fanSet, selected: .maximum), .manual)
    }

    /// Without fan readings (on a Mac that has fans) every section stays and
    /// Automatic stays available, so the palette can always hand the fans
    /// back to the system (the D64 palette had a separate 恢复 macOS 自动控制
    /// button for this); the modes that set speeds need each fan's verified
    /// range once, thermal protection (serious, critical) leaves only
    /// Automatic, and the curve also needs its profile and temperature.
    func testAutomaticStaysAvailableWithoutFanReadingsAndInThermalProtection() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let missing = FanTelemetryState(actualRPM: nil, minRPM: nil, maxRPM: nil, targetRPM: nil, fanCount: 0,
                timestamp: nil, telemetryAvailable: false, isSampling: false, isFanless: false, readings: [])
            XCTAssertEqual(FanControlPaletteAvailability.visibleModes(telemetry: missing),
                           [.systemAutomatic, .customCurve, .manual, .maximum])
            let verified = FanTelemetryState.resolve(snapshot: Self.snapshot(fans: [Self.cpu, Self.gpu]))
            // A snapshot drops readings that list a fan twice; telemetry built
            // from such readings directly still keeps the speed modes off-limits.
            XCTAssertNil(Self.snapshot(fans: [Self.cpu, Self.cpu]).fanReadings)
            let duplicate = FanTelemetryState(actualRPM: 2_000, minRPM: 1_000, maxRPM: 4_000, targetRPM: nil,
                fanCount: 2, timestamp: nil, telemetryAvailable: true, isSampling: false, isFanless: false,
                readings: [Self.cpu, Self.cpu])
            XCTAssertTrue(duplicate.hasVerifiedRanges, "each reading alone has a verified range")
            let range = L10n.text("风扇量程不可用 · 仅监测", "Fan Range Unavailable · Monitoring Only")
            let thermal = L10n.text("热保护中，只能使用自动控制", "Thermal protection: automatic control only")
            let curve = L10n.text("曲线或温度来源不可用", "Curve or temperature source unavailable")
            func reason(_ mode: GeekFanControlMode, _ telemetry: FanTelemetryState,
                        _ thermalState: SystemThermalState, curveIsAvailable: Bool = true) -> String? {
                FanControlPaletteView.disabledReason(mode: mode, telemetry: telemetry, helperState: .enabled,
                    thermalState: thermalState, isDataOnlyFixture: false, curveIsAvailable: curveIsAvailable)
            }
            let states: [SystemThermalState] = [.unknown, .nominal, .fair, .serious, .critical]
            for state in states {
                for telemetry in [missing, verified, duplicate] {
                    XCTAssertNil(reason(.systemAutomatic, telemetry, state, curveIsAvailable: false), "\(state)")
                }
            }
            for mode: GeekFanControlMode in [.customCurve, .manual, .maximum] {
                XCTAssertEqual(reason(mode, missing, .nominal), range, "\(mode)")
                XCTAssertEqual(reason(mode, duplicate, .nominal), range, "\(mode): a fan listed twice")
                for state in states {
                    let protected = state == .serious || state == .critical
                    XCTAssertEqual(reason(mode, verified, state), protected ? thermal : nil, "\(mode) \(state)")
                }
            }
            XCTAssertEqual(reason(.customCurve, verified, .nominal, curveIsAvailable: false), curve)
            XCTAssertNil(reason(.manual, verified, .nominal, curveIsAvailable: false))
            XCTAssertNil(reason(.maximum, verified, .nominal, curveIsAvailable: false))
        }
    }

    /// The notes under the sections: a preview's note, then the last
    /// message; otherwise, with the helper enabled, why the other modes are
    /// unavailable, each reason once. Without the helper the setup view
    /// above them explains, so no reasons are listed.
    func testTheNotesGiveEachReasonOnceThenTheLastMessage() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let telemetry = FanTelemetryState.resolve(snapshot: Self.snapshot(fans: [Self.cpu, Self.gpu]))
        func notes(_ fanControl: FanControlCoordinator, _ thermalState: SystemThermalState) -> [String] {
            FanControlPaletteView(presentation: ControlPalettePresentationState(), fanControl: fanControl,
                telemetry: telemetry, thermalState: thermalState).noteMessages
        }
        let thermal = L10n.text("热保护中，只能使用自动控制", "Thermal protection: automatic control only")
        let fanControl = Self.coordinator(defaults: defaults)
        defer { fanControl.disconnectForTermination() }
        for state: SystemThermalState in [.serious, .critical] {
            XCTAssertEqual(notes(fanControl, state), [thermal], "Custom Fan Curve, Manual and Maximum share one reason")
        }
        let profile = MiniWindowDemoData.hardwareControlProfile(for: .thermalSerious)
        let message = try XCTUnwrap(profile.message)
        let preview = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile,
            snapshot: MiniWindowDemoData.fixture.snapshot)
        XCTAssertEqual(notes(preview, .serious), [FanControlPaletteView.previewNote, message])
        let interrupted = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: false,
            requestSender: { request in
                XCTFail("No helper request expected: \(request.operation)")
                throw CancellationError()
            },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("Helper must not be registered") })
        defer { interrupted.disconnectForTermination() }
        XCTAssertEqual(interrupted.helperState, .connectionInterrupted)
        XCTAssertEqual(notes(interrupted, .serious), [], "the setup view explains instead")
    }

    /// The page is 8 + the sections 7 apart + 8. Automatic, Custom Fan Curve
    /// and our Maximum are 25 (a major label alone); Manual is 73 with one
    /// fan (5 + 15 + 2 + 16 + 30 + 5), 90 with two synchronized (+ 2 + 15 for
    /// Sync) and 128 with two apart (+ 8 + 30). With every mode available
    /// there is no note, so two synchronized fans make iStat's 202.
    func testTheRenderedPageIsIStatsFanSubmenu() throws {
        let third = SystemFanReading(index: 2, actualRPM: 2_500, minimumRPM: 1_500, maximumRPM: 5_000, targetRPM: nil)
        let cases: [(name: String, fans: [SystemFanReading], synchronized: Bool, manual: CGFloat)] = [
            ("one", [Self.cpu], true, 73),
            ("one-apart", [Self.cpu], false, 73),
            ("two", [Self.cpu, Self.gpu], true, 90),
            ("two-apart", [Self.cpu, Self.gpu], false, 128),
            ("three-apart", [Self.cpu, Self.gpu, third], false, 166),
        ]
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for page in cases {
                let suite = TestPreferenceDomain.makeSuite()
                let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
                defer { TestPreferenceDomain.cleanup(suiteName: suite) }
                let fanControl = Self.coordinator(defaults: defaults)
                defer { fanControl.disconnectForTermination() }
                let snapshot = Self.snapshot(fans: page.fans)
                fanControl.process(snapshot: snapshot)
                fanControl.setManualFansSynchronized(page.synchronized)
                let bitmap = try Self.render(FanControlPaletteView(
                    presentation: ControlPalettePresentationState(), fanControl: fanControl,
                    telemetry: FanTelemetryState.resolve(snapshot: snapshot), thermalState: .nominal))
                let tag = "\(language) \(page.name)"
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, ControlPaletteMetrics.fanSize.width, tag)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 8 + 25 + 7 + 25 + 7 + page.manual + 7 + 25 + 8, tag)
                XCTAssertNil(fanControl.requestedMode, tag)
                XCTAssertEqual(fanControl.selectedMode, .systemAutomatic, tag)
            }
        }
        XCTAssertEqual(ControlPaletteMetrics.fanSize, CGSize(width: 200, height: 8 + 25 + 7 + 25 + 7 + 90 + 7 + 25 + 8))
    }

    /// iStat saves every value as it changes and loads Sync on by default.
    /// Outside manual mode a value is only stored; Sync only switches between
    /// the shared and the per-fan sliders, whose values stay as stored (a fan
    /// without its own takes the shared one); a new session starts
    /// automatic. Our shared default stays 0.70, shared with Settings
    /// (iStat's is 0.5).
    func testSliderValuesAreSettingsThatPersist() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let first = Self.coordinator(defaults: defaults)
        XCTAssertTrue(first.synchronizesManualFans)
        XCTAssertEqual(first.manualPercentage(for: nil), FanControlPreferences.defaultManualFraction * 100, accuracy: 1e-9)
        XCTAssertEqual(first.manualPercentage(for: 1), FanControlPreferences.defaultManualFraction * 100, accuracy: 1e-9,
                       "while synchronized every fan reads the shared value")
        first.process(snapshot: Self.snapshot(fans: [Self.cpu, Self.gpu]))
        first.commitManualPercentage(40)
        first.setManualFansSynchronized(false)
        XCTAssertEqual(first.manualPercentage(for: 1), 40, accuracy: 1e-9, "a fan without its own value takes the shared one")
        first.updateManualPercentage(25, fanID: 0)
        first.commitManualPercentage(75, fanID: 1)
        XCTAssertFalse(first.hasPendingManualCommit, "outside manual mode a value is stored, not scheduled")
        XCTAssertEqual(first.manualPercentage(for: nil), 40, accuracy: 1e-9)
        XCTAssertEqual(first.manualPercentage(for: 0), 25, accuracy: 1e-9)
        XCTAssertEqual(first.manualPercentage(for: 1), 75, accuracy: 1e-9)
        first.setManualFansSynchronized(true)
        XCTAssertEqual(first.manualPercentage(for: 0), 40, accuracy: 1e-9, "synchronized fans read the shared value")
        first.setManualFansSynchronized(false)
        XCTAssertEqual(first.manualPercentage(for: 0), 25, accuracy: 1e-9, "Sync overwrites no value")
        first.disconnectForTermination()
        let restored = Self.coordinator(defaults: defaults)
        defer { restored.disconnectForTermination() }
        XCTAssertFalse(restored.synchronizesManualFans)
        XCTAssertEqual(restored.manualPercentage(for: nil), 40, accuracy: 1e-9)
        XCTAssertEqual(restored.manualPercentage(for: 0), 25, accuracy: 1e-9)
        XCTAssertEqual(restored.manualPercentage(for: 1), 75, accuracy: 1e-9)
        XCTAssertEqual(restored.selectedMode, .systemAutomatic, "a new session starts automatic")
    }

    /// iStat forces Sync with one fan: manual mode writes the shared value
    /// to it, never a per-fan value stored while two fans were apart. The
    /// shared 75 % of 1,000–4,000 is 3,250, the fan's speed; its own 25 %
    /// would ramp to 2,250 (± 1,000 on the first write).
    func testASingleFanTakesTheSharedValueInManualMode() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        var requests: [FanControlHelperRequest] = []
        let fanControl = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: { request in
                requests.append(request)
                return FanControlHelperReply(operation: request.operation, success: true,
                    message: "test readback", appliedTargetRPMByFan: request.targetRPMByFan)
            },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("Manual mode must not register Helper") })
        defer { fanControl.disconnectForTermination() }
        let fan = SystemFanReading(index: 0, identity: .cpu, actualRPM: 3_250, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil)
        fanControl.process(snapshot: Self.snapshot(fans: [fan]))
        fanControl.commitManualPercentage(75)
        fanControl.setManualFansSynchronized(false)
        fanControl.commitManualPercentage(25, fanID: 0)
        XCTAssertTrue(requests.isEmpty, "values outside manual mode are only stored")
        await fanControl.selectMode(.manual)
        for _ in 0..<100 where !requests.contains(where: { $0.operation == .apply }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests.first?.operation, .ping)
        let apply = try XCTUnwrap(requests.first { $0.operation == .apply })
        XCTAssertEqual(apply.targetRPMByFan, [0: 3_250], "one fan takes the shared slider")
        XCTAssertEqual(fanControl.selectedMode, .manual)
    }

    /// iStat's writes in manual mode: a drag step stores and writes 0.2 s
    /// after the last one; the release (as a press beside the knob or a
    /// VoiceOver step) and Sync write at once, so nothing stays pending.
    /// Apart, each fan takes its own stored value. The clock moves 4 s
    /// between writes, so the planner's 500 rpm/s limit holds no target back.
    func testManualModeWritesADragAfterTheDebounceAndTheRestAtOnce() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var applies: [[Int: Int]] = []
        let fanControl = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true, now: { clock },
            requestSender: { request in
                if request.operation == .apply { applies.append(request.targetRPMByFan) }
                return FanControlHelperReply(operation: request.operation, success: true,
                    message: "test readback", appliedTargetRPMByFan: request.targetRPMByFan)
            },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("Manual mode must not register Helper") })
        defer { fanControl.disconnectForTermination() }
        fanControl.process(snapshot: Self.snapshot(fans: [
            SystemFanReading(index: 0, identity: .cpu, actualRPM: 2_500, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
            SystemFanReading(index: 1, identity: .gpu, actualRPM: 4_000, minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil),
        ]))
        fanControl.commitManualPercentage(50)
        fanControl.setManualFansSynchronized(false)
        fanControl.commitManualPercentage(20, fanID: 0)
        fanControl.commitManualPercentage(90, fanID: 1)
        fanControl.setManualFansSynchronized(true)
        XCTAssertTrue(applies.isEmpty)
        func written(_ count: Int) async throws -> [Int: Int] {
            for _ in 0..<200 where applies.count < count || fanControl.isApplying {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(applies.count, count)
            clock += 4
            return applies.last ?? [:]
        }
        await fanControl.selectMode(.manual)
        var targets = try await written(1)
        XCTAssertEqual(targets, [0: 2_500, 1: 4_000], "manual mode writes the stored 50 %")
        fanControl.updateManualPercentage(60)
        XCTAssertTrue(fanControl.hasPendingManualCommit)
        XCTAssertEqual(applies.count, 1, "a drag step only stores")
        targets = try await written(2)
        XCTAssertEqual(targets, [0: 2_800, 1: 4_400])
        XCTAssertFalse(fanControl.hasPendingManualCommit)
        fanControl.commitManualPercentage(70)
        XCTAssertFalse(fanControl.hasPendingManualCommit, "the release does not wait")
        targets = try await written(3)
        XCTAssertEqual(targets, [0: 3_100, 1: 4_800])
        fanControl.setManualFansSynchronized(false)
        XCTAssertFalse(fanControl.hasPendingManualCommit, "Sync does not wait")
        targets = try await written(4)
        XCTAssertEqual(targets, [0: 1_600, 1: 5_600], "apart, each fan takes its own value")
        fanControl.commitManualPercentage(50, fanID: 1)
        XCTAssertFalse(fanControl.hasPendingManualCommit)
        targets = try await written(5)
        XCTAssertEqual(targets, [0: 1_600, 1: 4_000], "a fan's release writes only its value")
        fanControl.setManualFansSynchronized(true)
        targets = try await written(6)
        XCTAssertEqual(targets, [0: 3_100, 1: 4_800], "synchronized again, both take the shared 70 %")
        XCTAssertEqual(fanControl.selectedMode, .manual)
    }

    /// Apart, a fan without its own value takes the shared one in the plan
    /// as on its slider (iStat starts each fan at 0.5; ours share the
    /// default); synchronized, every fan takes the shared value.
    func testApartAFanWithoutItsOwnValueTakesTheSharedOne() {
        func targets(synchronized: Bool) -> [Int: Int]? {
            FanControlPlanner.plan(mode: .manual, fanSet: .balanced, manualFraction: 0.5,
                manualFractionByFan: [1: 0.25], synchronizesManualFans: synchronized,
                curveLowTemperature: 48, curveHighTemperature: 86, thermalState: .nominal,
                fanReadings: [Self.cpu, Self.gpu], temperatureReadings: nil)?.targetRPMByFan
        }
        XCTAssertEqual(targets(synchronized: false), [0: 2_500, 1: 3_000])
        XCTAssertEqual(targets(synchronized: true), [0: 2_500, 1: 4_000])
    }

    /// The stored per-fan values come back for real fans only: a negative or
    /// non-numeric key is dropped and a value outside 0 … 1 is clamped.
    func testStoredFanValuesComeBackForRealFansOnly() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        defaults.set(Data(#"{"-1": 0.3, "0": 2, "1": -0.5, "3": 0.25, "fan": 0.5}"#.utf8),
                     forKey: FanControlPreferences.manualFractionByFanKey)
        let fanControl = Self.coordinator(defaults: defaults)
        defer { fanControl.disconnectForTermination() }
        XCTAssertEqual(fanControl.manualFractionByFan, [0: 1, 1: 0, 3: 0.25])
        XCTAssertEqual(fanControl.manualPercentage(for: -1), 70, accuracy: 1e-9, "a dropped key takes the shared value")
    }

    /// A preview shows its profile's mode and value: the switches and the
    /// sliders read the coordinator, so the fixture holds them; a profile
    /// without them keeps the new session's Automatic and the shared 70 %.
    func testAPreviewShowsItsProfilesModeAndValue() throws {
        let cases: [(MiniWindowDemoData.HardwareControlDemoState, GeekFanControlMode, Double)] = [
            (.dualFanManual, .manual, 65), (.fanManual65, .manual, 65), (.fanMaximum, .maximum, 70),
            (.fanAutomatic, .systemAutomatic, 70), (.helperNotRegistered, .systemAutomatic, 70),
        ]
        for (state, mode, percentage) in cases {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let fixture = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults,
                profile: MiniWindowDemoData.hardwareControlProfile(for: state), snapshot: MiniWindowDemoData.fixture.snapshot)
            XCTAssertEqual(fixture.selectedMode, mode, "\(state)")
            XCTAssertEqual(fixture.manualPercentage(for: nil), percentage, accuracy: 1e-9, "\(state)")
        }
    }

    /// A preview (a data-only fixture) changes nothing: no mode, Sync or
    /// value, and every switch reads the preview note.
    func testAPreviewChangesNothing() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let state = MiniWindowDemoData.HardwareControlDemoState.dualFanManual
        let fixture = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults,
            profile: MiniWindowDemoData.hardwareControlProfile(for: state), snapshot: MiniWindowDemoData.fixture.snapshot)
        let mode = fixture.selectedMode
        let synchronized = fixture.synchronizesManualFans
        let fans: [Int?] = [nil, 0, 1]
        let values = fans.map { fixture.manualPercentage(for: $0) }
        fixture.setManualFansSynchronized(!synchronized)
        fixture.updateManualPercentage(10)
        fixture.commitManualPercentage(20, fanID: 1)
        await fixture.selectMode(.maximum)
        XCTAssertEqual(fixture.selectedMode, mode)
        XCTAssertEqual(fixture.synchronizesManualFans, synchronized)
        XCTAssertEqual(fans.map { fixture.manualPercentage(for: $0) }, values)
        XCTAssertFalse(fixture.hasPendingManualCommit)
        XCTAssertNil(fixture.requestedMode)
        let telemetry = MiniWindowDemoData.fanTelemetry(for: state)
        for mode: GeekFanControlMode in [.systemAutomatic, .customCurve, .manual, .maximum] {
            XCTAssertEqual(FanControlPaletteView.disabledReason(mode: mode, telemetry: telemetry, helperState: .enabled,
                thermalState: .nominal, isDataOnlyFixture: true, curveIsAvailable: true), FanControlPaletteView.previewNote)
        }
    }

    /// D152 (the dashboard's live apply): stored slider values are settings,
    /// so hiding Sensors is allowed with them; only a value not yet written
    /// in manual mode holds the fan controls open until it is (was: any
    /// per-fan value the helper had not confirmed).
    func testHidingSensorsWaitsOnlyForAValueNotYetWritten() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let fanControl = Self.coordinator(defaults: defaults)
        defer { fanControl.disconnectForTermination() }
        let store = GeekDashboardConfigurationStore(defaults: defaults, fanControlProvider: { fanControl })
        var hidden = store.configuration
        let sensors = try XCTUnwrap(hidden.modules.firstIndex { $0.module == .sensors })
        XCTAssertTrue(hidden.modules[sensors].isVisible)
        hidden.modules[sensors].isVisible = false
        fanControl.commitManualPercentage(30)
        fanControl.setManualFansSynchronized(false)
        fanControl.commitManualPercentage(60, fanID: 1)
        XCTAssertFalse(fanControl.hasPendingManualCommit)
        // Manual mode without a sample: the pending value is dropped, never sent.
        fanControl.selectedMode = .manual
        fanControl.updateManualPercentage(45)
        XCTAssertTrue(fanControl.hasPendingManualCommit)
        XCTAssertThrowsError(try store.applyLive(hidden)) { error in
            XCTAssertEqual(error.localizedDescription,
                           GeekDashboardConfigurationStore.CommitFailure.activeControl.errorDescription)
        }
        XCTAssertEqual(store.configuration.modules.first { $0.module == .sensors }?.isVisible, true)
        for _ in 0..<100 where fanControl.hasPendingManualCommit {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(fanControl.hasPendingManualCommit)
        try store.applyLive(hidden)
        XCTAssertEqual(store.configuration.modules.first { $0.module == .sensors }?.isVisible, false)
        XCTAssertEqual(fanControl.manualPercentage(for: 1), 60, accuracy: 1e-9, "hiding Sensors keeps the values")
    }

    /// A coordinator with the helper enabled whose transport fails the test.
    private static func coordinator(defaults: UserDefaults) -> FanControlCoordinator {
        FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: { request in
                XCTFail("No helper request expected: \(request.operation)")
                throw CancellationError()
            },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("Helper must not be registered") })
    }

    /// Fans with ranges and a chip temperature, so the curve has a source.
    private static func snapshot(fans: [SystemFanReading]) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil, thermalState: .nominal,
            fanReadings: fans, temperatureReadings: [SystemTemperatureReading(zone: .chip, celsius: 55)])
    }

    /// The palette's page as ControlPaletteRootView frames it, at 2×.
    private static func render<Content: View>(_ page: Content) throws -> NSBitmapImageRep {
        let content = page
            .frame(width: cardWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .controlSize(.small)
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: .black))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
}
#endif
