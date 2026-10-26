import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class ControlPaletteTests: XCTestCase {
    #if DEBUG || STORAGE_CLEANER_BETA
    func testReadOnlyFixturePublishesAutomaticReadbackAndPreservesUnknownMode() throws {
        for state in [MiniWindowDemoData.HardwareControlDemoState.dualFan, .helperEnabled] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let snapshot = fixtureSnapshot(profile)
            let coordinator = FanControlCoordinator.makeReadOnlyFixture(
                defaults: defaults, profile: profile, snapshot: snapshot
            )
            XCTAssertTrue(coordinator.isDataOnlyFixture)
            XCTAssertEqual(coordinator.observedMode, profile.observedMode)
            XCTAssertEqual(coordinator.helperState, .enabled)
            XCTAssertEqual(coordinator.latestFanReadings, profile.fanReadings)
            XCTAssertNotNil(coordinator.curvePreviewTemperature)
            XCTAssertNil(coordinator.requestedMode)
            coordinator.expireObservedModeIfNeeded()
            XCTAssertEqual(coordinator.observedMode, profile.observedMode)
            if state == .dualFan {
                XCTAssertEqual(coordinator.observedMode, .systemAutomatic)
                XCTAssertEqual(coordinator.latestFanReadings.count, 2)
            } else {
                XCTAssertNil(coordinator.observedMode, "Connected Helper does not imply automatic hardware mode")
            }
        }
    }
    #endif

    #if DEBUG || STORAGE_CLEANER_BETA
    func testReadOnlyFixtureRejectsEveryModePowerAndHelperAction() async throws {
        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(
            source: .acPower, mode: .highPower, setting: .powerMode
        ))
        for state in [MiniWindowDemoData.HardwareControlDemoState.fanAutomatic,
                      .helperNotRegistered, .awaitingSystemApproval] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let coordinator = FanControlCoordinator.makeReadOnlyFixture(
                defaults: defaults, profile: profile, snapshot: fixtureSnapshot(profile)
            )
            await coordinator.refreshConnection()
            await coordinator.registerHelper()
            await coordinator.migrateLegacyHelper()
            await coordinator.unregisterHelper()
            coordinator.openApprovalSettings()
            for mode in GeekFanControlMode.allCases {
                await coordinator.selectMode(mode)
            }
            await coordinator.applyFanCurveDraft()
            do {
                _ = try await coordinator.applyPowerMode(command)
                XCTFail("Data-only fixtures must reject power writes")
            } catch is CancellationError {
                // The fixture boundary rejects before any service call.
            }
            await coordinator.prepareForTermination()
            XCTAssertEqual(coordinator.helperState, profile.helperState)
            XCTAssertEqual(coordinator.observedMode, profile.observedMode)
            XCTAssertEqual(coordinator.lastMessage, profile.message)
            XCTAssertNil(coordinator.requestedMode)
            XCTAssertFalse(coordinator.isApplying)
            XCTAssertFalse(coordinator.isPreparingHelper)
        }
    }
    #endif

    func testFixtureFactorySealsTransportAndBothPaletteRoutesReuseProductionContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let coordinator = try source("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift")
        let factory = try XCTUnwrap(coordinator.components(separatedBy: "static func makeReadOnlyFixture(").last?
            .components(separatedBy: "#endif").first)
        XCTAssertTrue(factory.contains("requestSender: { _ in throw CancellationError() }"))
        XCTAssertTrue(factory.contains("serviceRegistrar: { throw CancellationError() }"))
        XCTAssertTrue(factory.contains("coordinator.observedMode = profile.observedMode"))
        XCTAssertFalse(factory.contains("selectMode("))
        XCTAssertFalse(factory.contains("publishObservedMode("))
        // fix1 added removal-only legacy decoding; fixtures still reject at
        // the first statement, before either legacy decoding or transport.
        XCTAssertTrue(coordinator.contains("private func send(_ request: FanControlHelperRequest,\n                      allowsLegacyRemovalFallback: Bool = false) async throws -> FanControlHelperReply {\n        guard !isDataOnlyFixture else { throw CancellationError() }"))
        let controller = try source("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift")
        XCTAssertTrue(controller.contains("if MiniWindowDemoData.isEnabled {\n            paletteFanControl = FanControlCoordinator.makeReadOnlyFixture("))
        XCTAssertTrue(controller.contains("fanControl: paletteFanControl"))
        XCTAssertTrue(controller.contains("static let shared = MenuBarStatusController()"))
        // D48: production defaults still use the singleton; injected instances
        // must reach both non-demo routes instead of being bypassed by .shared.
        XCTAssertTrue(controller.contains("init(fanControlProvider: @escaping @MainActor () -> FanControlCoordinator = { FanControlCoordinator.shared })"))
        XCTAssertTrue(controller.contains("private lazy var fanControl = fanControlProvider()"))
        XCTAssertTrue(controller.contains("} else {\n            paletteFanControl = fanControl\n        }\n#else\n        paletteFanControl = fanControl\n#endif"))
        XCTAssertEqual(controller.components(separatedBy: "paletteFanControl = fanControl").count - 1, 2)
        let routes = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(routes.contains("return FanControlCoordinator.makeReadOnlyFixture("))
        XCTAssertFalse(routes.contains("height: isExpanded ? 430 : 250"))
        XCTAssertTrue(routes.contains(".fixedSize(horizontal: false, vertical: true)"))
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(palette.contains("controlsEnabled: fanControl.helperState == .enabled && !fanControl.isDataOnlyFixture"))
        // D152: a fixture's toggles are off-limits behind the preview note and
        // its Sync row and sliders are disabled; the toggles call the
        // coordinator, whose fixture boundary rejects every write (were the
        // draft's "FIXTURE · 仅预览…" reason and `draft.selectMode(mode)`).
        XCTAssertFalse(palette.contains("FIXTURE"))
        XCTAssertTrue(palette.contains("if isDataOnlyFixture { return previewNote }"))
        XCTAssertFalse(palette.contains("draft.selectMode(mode)"))
        XCTAssertTrue(palette.contains("await fanControl.selectMode(mode)"))
        XCTAssertTrue(palette.contains("FanManualSliderList(fanControl: fanControl, readings: telemetry.readings)\n                .disabled(fanControl.isDataOnlyFixture)"))
        XCTAssertTrue(factory.contains("coordinator.selectedMode = mode"), "D152: the fixture shows its mode without selecting it")
        let editor = try source("Sources/StorageCleanerMac/Views/FanCurveEditor.swift")
        XCTAssertTrue(editor.contains("&& !fanControl.isDataOnlyFixture"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    private func fixtureSnapshot(_ profile: MiniWindowDemoData.HardwareControlDemoProfile) -> SystemMonitorSnapshot {
        let base = MiniWindowDemoData.fixture.snapshot
        return SystemMonitorSnapshot(
            generatedAt: base.generatedAt, metrics: base.metrics,
            networkThroughput: nil, thermalState: profile.thermalState,
            fanReadings: profile.fanReadings,
            temperatureReadings: base.temperatureReadings,
            sensorAvailability: profile.sensorAvailability
        )
    }
    #endif

    /// D152: the manual section shows iStat's sliders and no readback (was
    /// `FanManualSliderList.actualRPM`: the average 1_200 rpm of both fans for
    /// the shared slider, 0 for the stopped fan, 2_400, nil for a fan that is
    /// not there). Every fan, the stopped one too, gets its own slider under
    /// its name when not synchronized; one fan always uses the shared slider.
    func testManualReadbackUsesEveryFanForAverageAndPreservesStoppedFan() {
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            metrics: [],
            networkThroughput: nil,
            fanReadings: [
                SystemFanReading(index: 0, actualRPM: 0, minimumRPM: 1_200, maximumRPM: 6_000, targetRPM: nil),
                SystemFanReading(index: 1, actualRPM: 2_400, minimumRPM: 1_400, maximumRPM: 6_000, targetRPM: nil),
            ]
        ))
        let shared = [FanManualSliderList.Slider(fanID: nil, title: L10n.text("风扇", "Fans"))]
        XCTAssertEqual(FanManualSliderList.sliders(readings: telemetry.readings, synchronizes: false), [
            FanManualSliderList.Slider(fanID: 0, title: telemetry.readings[0].displayName),
            FanManualSliderList.Slider(fanID: 1, title: telemetry.readings[1].displayName),
        ])
        XCTAssertEqual(FanManualSliderList.sliders(readings: telemetry.readings, synchronizes: true), shared)
        XCTAssertEqual(FanManualSliderList.sliders(readings: [telemetry.readings[1]], synchronizes: false), shared)
        XCTAssertEqual(FanManualSliderList.sliders(readings: [], synchronizes: false), [])
        XCTAssertEqual(FanManualSliderList.sliders(readings: [telemetry.readings[0], telemetry.readings[0]],
                                                   synchronizes: false), [], "A fan listed twice shows no sliders")
        XCTAssertTrue(FanManualSliderList.isAvailable(for: telemetry))
        XCTAssertEqual(telemetry.readings.map(\.actualRPM), [0, 2_400], "The stopped fan's readback stays exact")
        XCTAssertEqual(FanManualSliderList.Slider(fanID: nil, title: "").id, -1)
        XCTAssertEqual(FanManualSliderList.Slider(fanID: 1, title: "").id, 1)
    }

    /// D152: no draft, Apply or Cancel. Outside manual mode the sliders and
    /// Sync only store their values, as iStat saves them, and nothing is
    /// sent or registered (was a draft whose mode, slider, sync and cancel
    /// never submitted and left the preferences unchanged).
    func testFanDraftSelectionSliderSyncPresetAndCancelNeverSubmit() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        var requests: [FanControlHelperRequest] = []
        var registrations = 0
        func makeCoordinator() -> FanControlCoordinator {
            FanControlCoordinator(
                defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                requestSender: { request in requests.append(request); throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled }, serviceRegistrar: { registrations += 1 }
            )
        }
        let coordinator = makeCoordinator()
        defer { coordinator.disconnectForTermination() }
        let telemetry = draftTelemetry()
        let originalReadings = telemetry.readings
        let persistedBefore = defaults.dictionaryRepresentation().mapValues { String(describing: $0) }
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertTrue(coordinator.synchronizesManualFans, "Sync starts on, as iStat's default")
        for percentage in 0...100 { coordinator.updateManualPercentage(Double(percentage)) }
        coordinator.commitManualPercentage(40)
        coordinator.setManualFansSynchronized(false)
        coordinator.commitManualPercentage(25, fanID: 0)
        coordinator.updateManualPercentage(75, fanID: 1)
        coordinator.setManualFansSynchronized(true)
        XCTAssertFalse(coordinator.hasPendingManualCommit)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertNil(coordinator.requestedMode)
        XCTAssertEqual(telemetry.readings, originalReadings)
        XCTAssertEqual(coordinator.manualPercentage(for: nil), 40, accuracy: 0.000_1)
        XCTAssertEqual(coordinator.manualPercentage(for: 0), 40, accuracy: 0.000_1, "Synchronized fans show the shared value")
        coordinator.setManualFansSynchronized(false)
        XCTAssertEqual(coordinator.manualPercentage(for: 0), 25, accuracy: 0.000_1)
        XCTAssertEqual(coordinator.manualPercentage(for: 1), 75, accuracy: 0.000_1)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(registrations, 0)
        // D152: the values are settings (was: the preferences unchanged).
        let persistedAfter = defaults.dictionaryRepresentation().mapValues { String(describing: $0) }
        let changedKeys = Set(persistedAfter.keys.filter { persistedAfter[$0] != persistedBefore[$0] })
            .union(persistedBefore.keys.filter { persistedAfter[$0] == nil })
        XCTAssertEqual(changedKeys, [
            FanControlPreferences.manualFractionKey,
            FanControlPreferences.manualSyncKey,
            FanControlPreferences.manualFractionByFanKey,
        ])
        let restored = makeCoordinator()
        defer { restored.disconnectForTermination() }
        XCTAssertFalse(restored.synchronizesManualFans)
        XCTAssertEqual(restored.manualPercentage(for: nil), 40, accuracy: 0.000_1)
        XCTAssertEqual(restored.manualPercentage(for: 0), 25, accuracy: 0.000_1)
        XCTAssertEqual(restored.manualPercentage(for: 1), 75, accuracy: 0.000_1)
        XCTAssertEqual(restored.selectedMode, .systemAutomatic, "A new session starts automatic")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(registrations, 0)
    }

    /// D152: the sliders' values map to each fan's RPM in the planner (was
    /// the draft's 25 % and 50 % for 1_750 and 4_000 rpm, its clamps to
    /// 1_000 and 4_000 rpm and its readback match). A fan without its own
    /// value takes the shared one; unknown ranges or a fan listed twice
    /// leave the speed-setting toggles off-limits and the planner empty.
    func testManualDraftMapsPerFanRPMAndRejectsUnknownRanges() throws {
        let telemetry = draftTelemetry()
        func plan(_ readings: [SystemFanReading], shared: Double, byFan: [Int: Double],
                  synchronized: Bool) -> FanControlPlan? {
            FanControlPlanner.plan(
                mode: .manual, fanSet: .balanced, manualFraction: shared, manualFractionByFan: byFan,
                synchronizesManualFans: synchronized, curveLowTemperature: 48, curveHighTemperature: 86,
                thermalState: .nominal, fanReadings: readings, temperatureReadings: nil)
        }
        XCTAssertEqual(plan(telemetry.readings, shared: 0.7, byFan: [0: 0.25, 1: 0.5], synchronized: false)?
            .targetRPMByFan, [0: 1_750, 1: 4_000])
        XCTAssertEqual(plan(telemetry.readings, shared: 0.7, byFan: [0: 0.25], synchronized: false)?
            .targetRPMByFan, [0: 1_750, 1: 4_800], "A fan without its own value takes the shared one")
        XCTAssertEqual(plan(telemetry.readings, shared: 0.5, byFan: [0: 0.25, 1: 1], synchronized: true)?
            .targetRPMByFan, [0: 2_500, 1: 4_000], "Synchronized fans take the shared value")
        XCTAssertEqual(FanControlPlanner.targetRPM(minimumRPM: 1_000, maximumRPM: 4_000, fraction: -1), 1_000)
        XCTAssertEqual(FanControlPlanner.targetRPM(minimumRPM: 1_000, maximumRPM: 4_000, fraction: 2), 4_000)
        XCTAssertEqual(FanControlPlanner.targetRPM(minimumRPM: 1_000, maximumRPM: 4_000, fraction: .nan), 1_000)
        XCTAssertTrue(FanManualSliderList.isAvailable(for: telemetry))
        XCTAssertNil(FanControlPaletteView.disabledReason(mode: .manual, telemetry: telemetry, helperState: .enabled,
            thermalState: .nominal, isDataOnlyFixture: false, curveIsAvailable: true))
        for readings in [
            [SystemFanReading(index: 0, actualRPM: 0, minimumRPM: nil, maximumRPM: nil, targetRPM: nil)],
            [telemetry.readings[0], telemetry.readings[0]],
        ] {
            let unavailable = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
                generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: readings
            ))
            XCTAssertFalse(FanManualSliderList.isAvailable(for: unavailable))
            XCTAssertNil(plan(unavailable.readings, shared: 1, byFan: [:], synchronized: true))
            for mode in [GeekFanControlMode.customCurve, .manual, .maximum] {
                XCTAssertEqual(FanControlPaletteView.disabledReason(mode: mode, telemetry: unavailable,
                    helperState: .enabled, thermalState: .nominal, isDataOnlyFixture: false, curveIsAvailable: true),
                    L10n.text("风扇量程不可用 · 仅监测", "Fan Range Unavailable · Monitoring Only"), "\(mode)")
            }
            XCTAssertNil(FanControlPaletteView.disabledReason(mode: .systemAutomatic, telemetry: unavailable,
                helperState: .enabled, thermalState: .nominal, isDataOnlyFixture: false, curveIsAvailable: true))
        }
    }

    /// D152: a value stored outside manual mode sends nothing; the manual
    /// toggle writes it through the existing verified chain and keeps it
    /// (was: only the draft's explicit submit of 2_500 rpm wrote).
    func testManualDraftOnlyExplicitSubmitUsesTheExistingVerifiedRequestChain() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        var requests: [FanControlHelperRequest] = []
        let coordinator = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: { request in
                requests.append(request)
                return FanControlHelperReply(operation: request.operation, success: true,
                    message: "test readback", appliedTargetRPMByFan: request.targetRPMByFan)
            },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("The manual toggle must not register Helper") }
        )
        defer { coordinator.disconnectForTermination() }
        let snapshot = SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: [SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: 2_000)])
        coordinator.process(snapshot: snapshot)
        coordinator.updateManualPercentage(80)
        coordinator.commitManualPercentage(50)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(coordinator.hasPendingManualCommit)
        await coordinator.selectMode(.manual)
        let confirmed = await eventually { coordinator.observedMode == .manual && !coordinator.isApplying }
        XCTAssertTrue(confirmed)
        XCTAssertTrue(requests.contains { $0.operation == .apply })
        XCTAssertTrue(requests.allSatisfy { [.ping, .apply, .renewFanControlLease].contains($0.operation) })
        XCTAssertEqual(requests.first(where: { $0.operation == .apply })?.targetRPMByFan, [0: 2_500])
        XCTAssertEqual(coordinator.manualPercentage(for: nil), 50, accuracy: 0.000_1,
            "The stored value is written, not replaced by the current speed")
        XCTAssertEqual(coordinator.latestFanReadings.first?.actualRPM, 2_000)
    }

    /// D152: Sync writes at once in manual mode. With one fan the targets
    /// stay the same, so the write renews the lease; while its reply is
    /// pending the coordinator stays busy, and after a success or a failure
    /// the stored value stays (was a same-RPM draft that stayed pending
    /// until the readback settled and survived a failure).
    func testSameRPMDraftWaitsForSettledReadbackAndSurvivesFailure() async throws {
        for succeeds in [false, true] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            var now = Date()
            let holdsWrites = R2TestValue(false)
            var pending: (FanControlHelperRequest, CheckedContinuation<FanControlHelperReply, Never>)?
            let coordinator = FanControlCoordinator(
                defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                now: { now },
                requestSender: { request in
                    if holdsWrites.value && [.apply, .renewFanControlLease].contains(request.operation) {
                        return await withCheckedContinuation { pending = (request, $0) }
                    }
                    return FanControlHelperReply(operation: request.operation, success: true,
                        message: "verified", appliedTargetRPMByFan: request.operation == .renewFanControlLease
                            ? [0: 2_500] : request.targetRPMByFan)
                },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled },
                serviceRegistrar: { XCTFail("A Sync write test must not register Helper") }
            )
            defer { coordinator.disconnectForTermination() }
            let snapshot = SystemMonitorSnapshot(generatedAt: now, metrics: [], networkThroughput: nil,
                fanReadings: [SystemFanReading(index: 0, actualRPM: 2_500, minimumRPM: 1_000,
                    maximumRPM: 4_000, targetRPM: 2_500)])
            coordinator.process(snapshot: snapshot)
            await coordinator.selectMode(.manual)
            coordinator.commitManualPercentage(50)
            let initiallyConfirmed = await eventually { coordinator.observedMode == .manual && !coordinator.isApplying }
            XCTAssertTrue(initiallyConfirmed)

            // Renew the same targets through the injected transport. Its reply
            // remains pending while the previous confirmed mode/targets remain.
            now.addTimeInterval(FanControlSafetyPolicy.leaseRenewalInterval + 0.1)
            holdsWrites.value = true
            coordinator.setManualFansSynchronized(!coordinator.synchronizesManualFans)
            let waiting = await eventually { pending != nil }
            XCTAssertTrue(waiting)
            XCTAssertTrue(coordinator.isApplying)
            XCTAssertFalse(coordinator.hasPendingManualCommit)
            XCTAssertEqual(pending?.0.operation, .renewFanControlLease)
            XCTAssertEqual(coordinator.observedMode, .manual)
            let reply = try XCTUnwrap(pending)
            pending = nil
            holdsWrites.value = false
            reply.1.resume(returning: FanControlHelperReply(operation: reply.0.operation,
                success: succeeds, message: succeeds ? "verified" : "rejected",
                appliedTargetRPMByFan: succeeds ? [0: 2_500] : [:]))
            let settled = await eventually { !coordinator.isApplying && !coordinator.isSwitchingMode }
            XCTAssertTrue(settled)
            XCTAssertEqual(coordinator.manualPercentage(for: nil), 50, accuracy: 0.000_1, "The stored value survives the reply")
            XCTAssertEqual(coordinator.latestFanReadings.first?.actualRPM, succeeds ? 2_500 : nil)
        }
    }

    /// D152: the toggles and sliders share one gate (was the draft's
    /// submit): a fixture shows the preview note and its coordinator stores
    /// and writes nothing; a helper that is not set up names its next step;
    /// thermal protection leaves only Automatic.
    func testDraftSubmissionRejectsFixtureUnapprovedAndThermallyProtectedStates() async throws {
        let telemetry = draftTelemetry()
        func reason(_ mode: GeekFanControlMode, helperState: HelperState,
                    thermalState: SystemThermalState = .nominal, fixture: Bool = false) -> String? {
            FanControlPaletteView.disabledReason(mode: mode, telemetry: telemetry, helperState: helperState,
                thermalState: thermalState, isDataOnlyFixture: fixture, curveIsAvailable: true)
        }
        #if DEBUG || STORAGE_CLEANER_BETA
        for state in [MiniWindowDemoData.HardwareControlDemoState.fanAutomatic, .fanReadOnly, .helperNotRegistered,
                      .awaitingSystemApproval, .connectionInterrupted, .dualFanManual] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let coordinator = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile, snapshot: fixtureSnapshot(profile))
            let selected = coordinator.selectedMode
            let percentage = coordinator.manualPercentage(for: nil)
            let synchronized = coordinator.synchronizesManualFans
            for mode in GeekFanControlMode.allCases {
                XCTAssertEqual(reason(mode, helperState: coordinator.helperState, fixture: coordinator.isDataOnlyFixture),
                               FanControlPaletteView.previewNote, "\(state) \(mode)")
            }
            await coordinator.selectMode(.manual)
            coordinator.updateManualPercentage(75)
            coordinator.commitManualPercentage(75, fanID: 0)
            coordinator.setManualFansSynchronized(!synchronized)
            XCTAssertEqual(coordinator.observedMode, profile.observedMode)
            XCTAssertEqual(coordinator.selectedMode, selected)
            XCTAssertNil(coordinator.requestedMode)
            XCTAssertFalse(coordinator.hasPendingManualCommit)
            XCTAssertEqual(coordinator.manualPercentage(for: nil), percentage, accuracy: 0.000_1)
            XCTAssertEqual(coordinator.synchronizesManualFans, synchronized)
            XCTAssertFalse(coordinator.isApplying)
        }
        #endif
        for helper in [FanControlHelperStatus.notRegistered, .requiresApproval, .enabled] {
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let coordinator = FanControlCoordinator(defaults: defaults, helperStatusOverride: helper,
                isHelperReachable: helper == .enabled,
                requestSender: { _ in XCTFail("Blocked toggles cannot reach transport"); throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .notRegistered },
                serviceRegistrar: { XCTFail("Blocked toggles cannot register Helper") })
            defer { coordinator.disconnectForTermination() }
            let thermalState: SystemThermalState = helper == .enabled ? .critical : .nominal
            for mode in [GeekFanControlMode.customCurve, .manual, .maximum] {
                XCTAssertEqual(reason(mode, helperState: coordinator.helperState, thermalState: thermalState),
                    helper == .enabled
                        ? L10n.text("热保护中，只能使用自动控制", "Thermal protection: automatic control only")
                        : FanControlSetupPresentation.reason(coordinator.helperState), "\(helper) \(mode)")
            }
            XCTAssertEqual(reason(.systemAutomatic, helperState: coordinator.helperState, thermalState: thermalState),
                helper == .enabled ? nil : FanControlSetupPresentation.reason(coordinator.helperState))
        }
    }

    private func draftTelemetry() -> FanTelemetryState {
        FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: [
                SystemFanReading(index: 0, actualRPM: 0, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: nil),
                SystemFanReading(index: 1, actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_000, targetRPM: nil),
            ]))
    }

    func testPlacementPrefersAttachedPositionsAndClampsToVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let ordinaryDecision = ControlPalettePlacement.decision(
            anchor: NSRect(x: 700, y: 600, width: 80, height: 60),
            size: CGSize(width: 250, height: 286),
            visibleFrame: visible
        )
        let ordinary = ordinaryDecision.frame
        XCTAssertTrue(visible.contains(ordinary))
        XCTAssertEqual(ordinaryDecision.edge, .below)
        XCTAssertEqual(ordinary.midX, 740)
        XCTAssertEqual(ordinary.maxY, 600 - ControlPaletteMetrics.gap)

        let nearEdge = ControlPalettePlacement.frame(
            anchor: NSRect(x: 2, y: 2, width: 20, height: 20),
            // D152: the removed curve-editor page's size (was ControlPaletteMetrics.fanCurveSize).
            size: CGSize(width: 354, height: 410),
            visibleFrame: visible
        )
        XCTAssertTrue(visible.contains(nearEdge))
        XCTAssertGreaterThanOrEqual(nearEdge.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(nearEdge.minY, visible.minY)
    }

    func testConnectionInspectorPrefersLeftAndFlipsRightAtScreenEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = ControlPaletteMetrics.networkConnectionSize
        let ordinaryAnchor = NSRect(x: 700, y: 500, width: 200, height: 31)
        let ordinary = ControlPalettePlacement.frame(
            anchor: ordinaryAnchor,
            size: size,
            visibleFrame: visible,
            gap: ControlPaletteMetrics.connectionGap,
            preference: .leftThenRight
        )
        XCTAssertEqual(
            ordinary.maxX,
            ordinaryAnchor.minX - ControlPaletteMetrics.connectionGap
        )
        XCTAssertTrue(visible.contains(ordinary))

        let edgeAnchor = NSRect(x: 5, y: 500, width: 200, height: 31)
        let flipped = ControlPalettePlacement.frame(
            anchor: edgeAnchor,
            size: size,
            visibleFrame: visible,
            gap: ControlPaletteMetrics.connectionGap,
            preference: .leftThenRight
        )
        XCTAssertEqual(
            flipped.minX,
            edgeAnchor.maxX + ControlPaletteMetrics.connectionGap
        )
        XCTAssertTrue(visible.contains(flipped))
    }

    func testSideInspectorTopAlignsWithItsOwningRow() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let anchor = NSRect(x: 700, y: 500, width: 200, height: 31)
        let frame = ControlPalettePlacement.frame(
            anchor: anchor,
            size: ControlPaletteMetrics.powerSize,
            visibleFrame: visible,
            preference: .leftThenRight
        )

        XCTAssertEqual(frame.maxY, anchor.maxY, accuracy: 0.001)
        XCTAssertEqual(
            frame.maxX,
            anchor.minX - ControlPaletteMetrics.gap,
            accuracy: 0.001
        )
        XCTAssertEqual(ControlPaletteMetrics.gap, 0)
    }

    func testSideInspectorNeverFallsBackAboveOrBelow() {
        let decision = ControlPalettePlacement.decision(
            anchor: NSRect(x: 700, y: 500, width: 200, height: 31),
            size: ControlPaletteMetrics.powerSize,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            preference: .leftThenRight,
            previousEdge: .below
        )

        XCTAssertTrue(decision.edge == .left || decision.edge == .right)
        XCTAssertEqual(decision.frame.maxY, 531, accuracy: 0.001)
    }

    func testConnectionInspectorStaysLeftWhenOnlyTopEdgeNeedsClamping() {
        let visible = NSRect(x: 6, y: 79, width: 1_340, height: 764)
        let anchor = NSRect(x: 505, y: 647, width: 296, height: 31)
        let frame = ControlPalettePlacement.frame(
            anchor: anchor,
            size: ControlPaletteMetrics.networkConnectionSize,
            visibleFrame: visible,
            gap: ControlPaletteMetrics.connectionGap,
            preference: .leftThenRight
        )

        XCTAssertEqual(frame.maxX, anchor.minX - ControlPaletteMetrics.connectionGap)
        XCTAssertEqual(frame.maxY, anchor.maxY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testConnectionInspectorKeepsSharedGapFromParentPanelEdge() {
        let parent = NSPanel(
            contentRect: NSRect(x: 497, y: 288, width: 619, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 73, width: 1_352, height: 776),
            presentsPanelOnShow: false
        )

        coordinator.toggle(
            .networkConnection,
            anchorScreenRect: NSRect(x: 505, y: 647, width: 296, height: 31),
            parentWindow: parent
        )

        XCTAssertEqual(
            coordinator.panel.frame.maxX,
            parent.frame.minX - ControlPaletteMetrics.connectionGap
        )
        XCTAssertTrue(NSRect(x: 6, y: 79, width: 1_340, height: 764)
            .contains(coordinator.panel.frame))
    }

    func testPowerPaletteUsesItsOwningRowInsideTheSecondaryColumn() {
        let parent = NSPanel(
            contentRect: NSRect(x: 900, y: 120, width: 608, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let row = NSRect(x: 916, y: 204, width: 280, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )

        let secondaryColumn = NSRect(x: 900, y: 120, width: 304, height: 553)
        coordinator.updatePlacementAnchor(secondaryColumn)
        coordinator.toggle(.power, anchorScreenRect: row, parentWindow: parent)

        XCTAssertEqual(
            coordinator.panel.frame.maxY,
            max(row.maxY, coordinator.panel.frame.height + 6),
            accuracy: 0.001
        )
        XCTAssertEqual(
            coordinator.panel.frame.maxX,
            secondaryColumn.minX - ControlPaletteMetrics.gap,
            accuracy: 0.001
        )

        let movedRow = row.offsetBy(dx: 0, dy: 180)
        coordinator.beginHover(.power, anchorScreenRect: movedRow, parentWindow: parent)

        XCTAssertEqual(
            coordinator.panel.frame.maxY,
            movedRow.maxY,
            accuracy: 0.001,
            "The power palette must follow its owning row in the secondary column"
        )
    }

    func testPaletteReplacesAttachedTertiaryBeforePlacement() {
        let parent = NSPanel(
            contentRect: NSRect(x: 624, y: 120, width: 884, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let row = NSRect(x: 916, y: 204, width: 280, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )
        var replacementCount = 0
        coordinator.willPresent = { _ in
            replacementCount += 1
            parent.setFrame(
                NSRect(x: 900, y: 120, width: 608, height: 553),
                display: false
            )
            coordinator.updatePlacementAnchor(
                NSRect(x: 900, y: 120, width: 304, height: 553)
            )
        }

        coordinator.toggle(.power, anchorScreenRect: row, parentWindow: parent)

        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(
            coordinator.panel.frame.maxX,
            parent.frame.minX - ControlPaletteMetrics.gap,
            accuracy: 0.001
        )
        XCTAssertEqual(coordinator.panel.frame.maxY, max(row.maxY, coordinator.panel.frame.height + 6), accuracy: 0.001)
    }

    func testMeasuredContentHeightRemovesUnusedBottomSpaceWithoutChangingWidth() {
        let parent = NSPanel(
            contentRect: NSRect(x: 900, y: 120, width: 608, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let row = NSRect(x: 916, y: 420, width: 280, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )

        coordinator.toggle(.power, anchorScreenRect: row, parentWindow: parent)
        coordinator.state.reportMeasuredContentSize(CGSize(width: ControlPaletteMetrics.powerSize.width, height: 171))

        XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.powerSize.width)
        XCTAssertEqual(coordinator.panel.frame.height, 171, accuracy: 0.001)
        XCTAssertEqual(coordinator.panel.frame.maxY, max(row.maxY, coordinator.panel.frame.height + 6), accuracy: 0.001)
    }

    func testNativeHostingMeasuresCompactExpandedAndEditorWithoutAutomaticWindowSizing() async throws {
        let layout = ControlPaletteTestLayout()
        let parent = NSPanel(
            contentRect: NSRect(x: 633, y: 37, width: 616, height: 756),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_280, height: 810)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        ) { presentation in
            AnyView(ControlPaletteTestContent(presentation: presentation, layout: layout))
        }
        defer { coordinator.teardown() }
        let host = try XCTUnwrap(coordinator.panel.contentView as? NSHostingView<AnyView>)
        XCTAssertEqual(host.sizingOptions, [])
        XCTAssertNil(coordinator.panel.contentViewController)
        coordinator.toggle(
            .fan,
            anchorScreenRect: NSRect(x: 649, y: 211, width: 280, height: 22),
            parentWindow: parent
        )

        for height: CGFloat in [248, 582, 248] {
            layout.height = height
            let measured = await eventually {
                host.layoutSubtreeIfNeeded()
                return coordinator.state.measuredContentHeight == height
                    && abs(coordinator.panel.frame.height - height) < 0.001
            }
            XCTAssertTrue(measured, "The real hosting layout must report the new content height \(height)")
            XCTAssertTrue(visibleFrame.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
            XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)
            XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
            let stableFrame = coordinator.panel.frame
            for _ in 0..<5 {
                coordinator.state.reportMeasuredContentSize(CGSize(width: ControlPaletteMetrics.fanSize.width, height: height + 0.25))
            }
            XCTAssertEqual(coordinator.panel.frame, stableFrame, "Subpixel measurement noise must not move the window")
        }

        // D152: no curve-editor page (F6); a taller page keeps the fan width
        // (was showFanCurveEditor() measuring 650 at fanCurveSize's width,
        // then showFanControls() back to 248).
        layout.height = 650
        let tallMeasured = await eventually {
            host.layoutSubtreeIfNeeded()
            return coordinator.state.measuredContentHeight == 650
                && coordinator.panel.frame.height == 650
                && coordinator.panel.frame.width == ControlPaletteMetrics.fanSize.width
        }
        XCTAssertTrue(tallMeasured)
        XCTAssertTrue(visibleFrame.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.presentationCount, 1, "Changing content reuses the existing palette")

        layout.height = 248
        let controlsMeasured = await eventually {
            host.layoutSubtreeIfNeeded()
            return coordinator.panel.frame.height == 248
                && coordinator.panel.frame.width == ControlPaletteMetrics.fanSize.width
        }
        XCTAssertTrue(controlsMeasured)
        XCTAssertFalse(coordinator.panel.isVisible, "This regression must not show a real window or invoke hardware")
    }

    func testNativeResizeRecoversOutOfBoundsFrameWhenNoPreferenceMeasurementArrives() async throws {
        let parent = NSPanel(
            contentRect: NSRect(x: 633, y: 37, width: 616, height: 756),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let productionSource = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Support/ControlPaletteCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(productionSource.contains("let visibleFrame = fixedVisibleFrame ?? screen.visibleFrame"),
            "Production placement must exclude the Dock and menu bar, not use the full screen frame")
        // Native observation: screen 1352×878, Dock reserves y=0…73 and
        // the menu bar starts at y=849. Preserve content size inside this area.
        let bounds = NSRect(x: 0, y: 73, width: 1_352, height: 776)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: bounds, presentsPanelOnShow: false
        )
        defer { coordinator.teardown() }
        coordinator.toggle(
            .fan,
            anchorScreenRect: NSRect(x: 649, y: 211, width: 280, height: 22),
            parentWindow: parent
        )
        // Reproduce native hosting growth with the compact window's top held
        // fixed. EmptyView supplies no SwiftUI PreferenceKey measurement.
        for size in [CGSize(width: 270, height: 248), CGSize(width: 354, height: 659), CGSize(width: 270, height: 248)] {
            coordinator.panel.setFrame(
                NSRect(x: 363, y: 254 - size.height, width: size.width, height: size.height),
                display: false
            )
            let recovered = await eventually {
                coordinator.state.measuredContentHeight == size.height
                    && coordinator.state.measuredContentWidth == size.width
                    && bounds.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame)
            }
            XCTAssertTrue(recovered, "AppKit's native resize notification must recover both dimensions \(size)")
            XCTAssertEqual(coordinator.panel.frame.size, size, "Keep the complete measured content size")
            XCTAssertGreaterThanOrEqual(coordinator.panel.frame.minY, 73)
            XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)
        }
        XCTAssertFalse(coordinator.panel.isVisible)
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    /// D152: the switches show the selection as iStat's do: automatic until a
    /// toggle asks for another mode, which shows at once; a fixed fan set
    /// shows as manual. The confirmed readback stays on the sensors page's
    /// entry (was the compact automatic summary, kept only for a confirmed
    /// automatic readback without a draft, a busy state or the expansion,
    /// and a cancelled draft). A fixture's sliders and Sync change nothing;
    /// the page grows with a second fan's Sync row and shrinks back, hidden
    /// and without a write.
    func testConfirmedAutomaticUsesShortNativeLayoutAndCancelledDraftNeverWrites() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let profile = MiniWindowDemoData.hardwareControlProfile(for: .fanAutomatic)
        let snapshot = fixtureSnapshot(profile)
        let fanControl = FanControlCoordinator.makeReadOnlyFixture(
            defaults: defaults, profile: profile, snapshot: snapshot)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: fanControl.requestedMode,
                                                           selected: fanControl.selectedMode), .systemAutomatic)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: nil, selected: .systemAutomatic), .systemAutomatic)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: .manual, selected: .systemAutomatic), .manual,
                       "A requested mode shows at once")
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: .systemAutomatic, selected: .manual), .systemAutomatic)
        XCTAssertEqual(FanControlPaletteView.displayedMode(requested: nil, selected: .fanSet), .manual)
        fanControl.commitManualPercentage(75)
        fanControl.setManualFansSynchronized(false)
        XCTAssertEqual(fanControl.manualPercentage(for: nil), FanControlPreferences.defaultManualFraction * 100, accuracy: 0.000_1)
        XCTAssertTrue(fanControl.synchronizesManualFans)
        XCTAssertNil(fanControl.requestedMode)
        XCTAssertFalse(fanControl.isApplying)
        XCTAssertEqual(fanControl.latestFanReadings, snapshot.fanReadings)
        XCTAssertTrue(fanControl.isDataOnlyFixture)

        let store = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults, cleanReportLoader: { [] })
        store.menuBarMonitorState.update(snapshot)
        let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let parent = NSPanel(contentRect: NSRect(x: 633, y: 81, width: 616, height: 760),
            styleMask: .borderless, backing: .buffered, defer: false)
        let visible = NSRect(x: 0, y: 73, width: 1_352, height: 776)
        let coordinator = ControlPaletteCoordinator(fixedVisibleFrame: visible, presentsPanelOnShow: false) { presentation in
            AnyView(ControlPaletteRootView(presentation: presentation, store: store,
                computerHealthStore: health, fanControl: fanControl))
        }
        defer { coordinator.teardown() }
        let host = try XCTUnwrap(coordinator.panel.contentView as? NSHostingView<AnyView>)
        coordinator.toggle(.fan, anchorScreenRect: NSRect(x: 649, y: 211, width: 280, height: 22), parentWindow: parent)
        func updateMeasurement() -> Bool {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            return coordinator.state.measuredContentHeight != nil
                && coordinator.panel.frame.height == coordinator.state.measuredContentHeight
        }
        let measured = await eventually { updateMeasurement() }
        XCTAssertTrue(measured)
        let singleFanHeight = coordinator.panel.frame.height
        XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
        // D152: a second fan adds the Sync row (was setFanControlsExpanded(true)).
        store.menuBarMonitorState.update(fixtureSnapshot(MiniWindowDemoData.hardwareControlProfile(for: .dualFan)))
        let grown = await eventually { updateMeasurement() && coordinator.panel.frame.height > singleFanHeight }
        XCTAssertTrue(grown, "The Sync row must remeasure the page")
        XCTAssertTrue(visible.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)
        XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
        store.menuBarMonitorState.update(snapshot)
        let shrunk = await eventually { updateMeasurement() && abs(coordinator.panel.frame.height - singleFanHeight) < 0.5 }
        XCTAssertTrue(shrunk)
        XCTAssertEqual(coordinator.presentationCount, 1)
        XCTAssertFalse(coordinator.panel.isVisible, "Native measurement stays hidden and must not operate the app")
        XCTAssertEqual(fanControl.observedMode, .systemAutomatic)
        XCTAssertNil(fanControl.requestedMode)
        XCTAssertFalse(fanControl.isApplying)
    }
    #endif

    /// D152: the production root measures the sections in the hidden native
    /// panel at the fan width; turning Sync off adds a slider per fan and
    /// turning it on again removes them, in automatic mode without a write
    /// (was compact → expanded details → the curve editor at its own width
    /// → compact, with one fan).
    func testProductionRootMeasuresFanControlsAndEditorInsideHiddenNativePanel() async throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let fanControl = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                XCTAssertEqual(request.operation, .ping, "Opening a fan page must not request a hardware write")
                throw CancellationError()
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("A layout test must never register Helper") }
        )
        let store = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults, cleanReportLoader: { [] })
        let snapshot = SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: [
                SystemFanReading(index: 0, actualRPM: 1_620, minimumRPM: 1_200, maximumRPM: 6_000, targetRPM: nil),
                // D152: a second fan for the Sync row (was one fan).
                SystemFanReading(index: 1, actualRPM: 1_800, minimumRPM: 1_300, maximumRPM: 6_000, targetRPM: nil),
            ],
            temperatureReadings: [SystemTemperatureReading(zone: .chip, celsius: 51)]
        )
        store.menuBarMonitorState.update(snapshot)
        fanControl.process(snapshot: snapshot)
        let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let parent = NSPanel(
            contentRect: NSRect(x: 633, y: 37, width: 616, height: 756),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        let bounds = NSRect(x: 0, y: 0, width: 1_280, height: 810).insetBy(dx: 6, dy: 6)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: bounds.insetBy(dx: -6, dy: -6),
            presentsPanelOnShow: false
        ) { presentation in
            AnyView(ControlPaletteRootView(
                presentation: presentation, store: store,
                computerHealthStore: health, fanControl: fanControl
            ))
        }
        defer { coordinator.teardown() }
        let host = try XCTUnwrap(coordinator.panel.contentView as? NSHostingView<AnyView>)
        coordinator.toggle(
            .fan,
            anchorScreenRect: NSRect(x: 649, y: 211, width: 280, height: 22),
            parentWindow: parent
        )
        let compactMeasured = await eventually {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            return coordinator.state.measuredContentHeight != nil
                && coordinator.panel.frame.height == coordinator.state.measuredContentHeight
        }
        XCTAssertTrue(compactMeasured, "The production root must publish its first content measurement")
        let compactHeight = coordinator.panel.frame.height
        XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
        XCTAssertTrue(fanControl.synchronizesManualFans)
        fanControl.setManualFansSynchronized(false)
        let expandedMeasured = await eventually {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            return coordinator.panel.frame.height > compactHeight + 0.5
                && coordinator.panel.frame.height == coordinator.state.measuredContentHeight
        }
        XCTAssertTrue(expandedMeasured,
            "Per-fan sliders must grow the native measurement: synced=\(compactHeight), per fan=\(coordinator.panel.frame.height)")
        XCTAssertTrue(bounds.contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)
        XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
        fanControl.setManualFansSynchronized(true)
        let collapsed = await eventually {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            return abs(coordinator.panel.frame.height - compactHeight) < 0.5
                && coordinator.panel.frame.width == ControlPaletteMetrics.fanSize.width
        }
        XCTAssertTrue(collapsed)
        XCTAssertFalse(coordinator.panel.isVisible)
        XCTAssertNil(fanControl.observedMode, "Layout changes must not confirm a hardware mode")
        XCTAssertFalse(fanControl.hasPendingManualCommit)
    }

    func testOnePanelIsReusedAcrossOneHundredOpenCloseCycles() {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 400, width: 304, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )
        let panelIdentity = ObjectIdentifier(coordinator.panel)
        let anchor = NSRect(x: 690, y: 560, width: 72, height: 72)

        for _ in 0..<100 {
            coordinator.toggle(.fan, anchorScreenRect: anchor, parentWindow: parent)
            XCTAssertTrue(coordinator.isPresented)
            XCTAssertEqual(coordinator.state.kind, .fan)
            coordinator.toggle(.fan, anchorScreenRect: anchor, parentWindow: parent)
            XCTAssertFalse(coordinator.isPresented)
        }

        XCTAssertEqual(ObjectIdentifier(coordinator.panel), panelIdentity)
        XCTAssertEqual(coordinator.presentationCount, 100)
    }

    func testConnectionHoverDelayBridgeAndDelayedDismissal() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(20),
            inspectorCloseDelay: .milliseconds(30),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(
            .networkConnection,
            anchorScreenRect: anchor,
            parentWindow: parent
        )
        try? await Task.sleep(for: .milliseconds(5))
        coordinator.endHover(.networkConnection)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(coordinator.isPresented)

        coordinator.beginHover(
            .networkConnection,
            anchorScreenRect: anchor,
            parentWindow: parent
        )
        let didOpen = await eventually { coordinator.isPresented }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(coordinator.connectionInspectorState, .open)

        coordinator.endHover(.networkConnection)
        coordinator.panel.onPointerPresenceChanged?(true)
        let didEnterInspector = await eventually {
            coordinator.isPointerInsideInspector
        }
        XCTAssertTrue(didEnterInspector)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(coordinator.isPresented)

        coordinator.panel.onPointerPresenceChanged?(false)
        let didClose = await eventually { !coordinator.isPresented }
        XCTAssertTrue(didClose)
        XCTAssertEqual(coordinator.connectionInspectorState, .closed)
    }

    func testPowerModeHoverOpensAttachedPaletteAndCrossingKeepsItVisible() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(20),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(.power, anchorScreenRect: anchor, parentWindow: parent)
        let didOpen = await eventually {
            coordinator.isPresented && coordinator.state.kind == .power
        }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(coordinator.state.kind, .power)
        XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap)

        coordinator.endHover(.power)
        coordinator.panel.onPointerPresenceChanged?(true)
        try? await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(coordinator.isPresented)

        coordinator.panel.onPointerPresenceChanged?(false)
        let didClose = await eventually { !coordinator.isPresented }
        XCTAssertTrue(didClose)
    }

    func testFanHoverOpensAttachedPaletteAndClickPinsIt() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 470, width: 260, height: 24)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(20),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(.fan, anchorScreenRect: anchor, parentWindow: parent)
        let didOpen = await eventually {
            coordinator.isPresented && coordinator.state.kind == .fan
        }
        XCTAssertTrue(didOpen)

        // Entering the palette keeps it alive after the anchor hover ends.
        coordinator.endHover(.fan)
        coordinator.panel.onPointerPresenceChanged?(true)
        try? await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(coordinator.isPresented)

        // Editing inside the hover-presented palette pins it without another
        // click on its source row, so dragging controls cannot dismiss a draft.
        coordinator.state.beginInteraction()
        coordinator.panel.onPointerPresenceChanged?(false)
        try? await Task.sleep(for: .milliseconds(45))
        XCTAssertTrue(coordinator.isPresented)

        coordinator.toggle(.fan, anchorScreenRect: anchor, parentWindow: parent)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testPowerPaletteAttachesToVisibleSecondaryColumnInUnionWindow() async {
        let unionWindow = NSPanel(
            contentRect: NSRect(x: 300, y: 200, width: 884, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let secondaryColumn = NSRect(x: 568, y: 200, width: 260, height: 553)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5)
        )

        // The panel session resolves the secondary column before the palette
        // binds to its parent window. Preserve that real presentation order.
        coordinator.updatePlacementAnchor(secondaryColumn)
        let row = NSRect(x: 576, y: 420, width: 244, height: 25)
        coordinator.beginHover(
            .power,
            anchorScreenRect: row,
            parentWindow: unionWindow
        )
        let didOpen = await eventually {
            coordinator.isPresented && coordinator.state.kind == .power
        }

        XCTAssertTrue(didOpen)
        XCTAssertEqual(
            coordinator.panel.frame.maxX,
            secondaryColumn.minX - ControlPaletteMetrics.gap
        )
        XCTAssertEqual(
            coordinator.panel.frame.maxY,
            max(row.maxY, coordinator.panel.frame.height + 6),
            accuracy: 0.001
        )

        unionWindow.setFrameOrigin(NSPoint(x: 360, y: 240))
        let movedSecondaryColumn = secondaryColumn.offsetBy(dx: 60, dy: 40)
        let movedRow = row.offsetBy(dx: 60, dy: 40)
        coordinator.parentWindowDidMove()
        XCTAssertEqual(
            coordinator.panel.frame.maxX,
            movedSecondaryColumn.minX - ControlPaletteMetrics.gap
        )
        XCTAssertEqual(
            coordinator.panel.frame.maxY,
            movedRow.maxY,
            accuracy: 0.001
        )
        coordinator.dismiss()
    }

    func testClickPinsHoveredPowerModePalette() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(10),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(.power, anchorScreenRect: anchor, parentWindow: parent)
        let didOpen = await eventually {
            coordinator.isPresented && coordinator.state.kind == .power
        }
        XCTAssertTrue(didOpen)
        coordinator.toggle(.power, anchorScreenRect: anchor, parentWindow: parent)
        coordinator.endHover(.power)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.isPresented)

        coordinator.toggle(.power, anchorScreenRect: anchor, parentWindow: parent)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testOldAnchorExitCannotCancelLatestPowerHover() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(10)
        )

        coordinator.beginHover(
            .networkConnection,
            anchorScreenRect: NSRect(x: 520, y: 580, width: 260, height: 31),
            parentWindow: parent
        )
        coordinator.beginHover(
            .power,
            anchorScreenRect: NSRect(x: 520, y: 520, width: 260, height: 31),
            parentWindow: parent
        )
        coordinator.endHover(.networkConnection)

        let didOpenPower = await eventually {
            coordinator.isPresented && coordinator.state.kind == .power
        }
        XCTAssertTrue(didOpenPower)
        coordinator.dismiss()
    }

    private final class PointerBox {
        var value: NSPoint

        init(_ value: NSPoint) {
            self.value = value
        }
    }

    func testClaimsHoverPointerCoversAnchorPaletteAndCorridor() {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 25)
        let pointer = PointerBox(NSPoint(x: -1_000, y: -1_000))
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            pointerLocationProvider: { pointer.value }
        )

        XCTAssertFalse(coordinator.claimsHoverPointer(), "nothing presented")

        coordinator.toggle(.power, anchorScreenRect: anchor, parentWindow: parent)
        XCTAssertTrue(coordinator.isPresented)
        let paletteFrame = coordinator.panel.frame
        XCTAssertLessThanOrEqual(paletteFrame.maxX, parent.frame.minX)

        pointer.value = NSPoint(x: anchor.midX, y: anchor.midY)
        XCTAssertTrue(coordinator.claimsHoverPointer(), "inside the anchor row")

        pointer.value = NSPoint(x: paletteFrame.midX, y: paletteFrame.midY)
        XCTAssertTrue(coordinator.claimsHoverPointer(), "inside the palette")

        pointer.value = NSPoint(
            x: (paletteFrame.maxX + anchor.minX) / 2,
            y: (paletteFrame.midY + anchor.midY) / 2
        )
        XCTAssertTrue(coordinator.claimsHoverPointer(), "traveling through the corridor")

        pointer.value = NSPoint(x: anchor.midX, y: anchor.maxY + 300)
        XCTAssertFalse(coordinator.claimsHoverPointer(), "far outside the envelope")

        pointer.value = NSPoint(x: paletteFrame.midX, y: paletteFrame.midY)
        coordinator.dismiss()
        XCTAssertFalse(coordinator.claimsHoverPointer(), "dismissed palette claims nothing")
    }

    func testDismissingPowerPalettePreservesNewerTertiaryOwnership() {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hoverController = HoverIntentController()
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            hoverIntentController: hoverController
        )
        let tertiaryAnchor = SmallWindowAnchorID.tertiary("battery")

        coordinator.toggle(
            .power,
            anchorScreenRect: NSRect(x: 520, y: 520, width: 260, height: 31),
            parentWindow: parent
        )
        hoverController.markOpen(anchorID: tertiaryAnchor, panelRole: .tertiary)
        coordinator.dismiss()

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(
            hoverController.state,
            .open(anchorID: tertiaryAnchor, panelRole: .tertiary)
        )
    }

    func testReturningToConnectionAnchorCancelsPendingClose() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(30),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(.networkConnection, anchorScreenRect: anchor, parentWindow: parent)
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.endHover(.networkConnection)
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.beginHover(.networkConnection, anchorScreenRect: anchor, parentWindow: parent)
        try? await Task.sleep(for: .milliseconds(35))

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.connectionInspectorState, .open)
        coordinator.dismiss()
    }

    func testClickPinsAHoveredInspectorAndSecondClickClosesIt() async {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 300, width: 304, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchor = NSRect(x: 520, y: 520, width: 260, height: 31)
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false,
            inspectorOpenDelay: .milliseconds(5),
            inspectorCloseDelay: .milliseconds(10),
            pointerLocationProvider: { NSPoint(x: -1_000, y: -1_000) }
        )

        coordinator.beginHover(.networkConnection, anchorScreenRect: anchor, parentWindow: parent)
        try? await Task.sleep(for: .milliseconds(10))
        coordinator.toggle(.networkConnection, anchorScreenRect: anchor, parentWindow: parent)
        coordinator.endHover(.networkConnection)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(coordinator.isPresented)

        coordinator.toggle(.networkConnection, anchorScreenRect: anchor, parentWindow: parent)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testInspectorAddsNoParallelEventOrNetworkMonitor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Support/ControlPaletteCoordinator.swift"
            ),
            encoding: .utf8
        )
        let trackingSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Support/MenuBarStatusPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("MenuBarPanelPointerTrackingView"))
        XCTAssertTrue(trackingSource.contains("NSTrackingArea("))
        XCTAssertFalse(source.contains("NSEvent.addLocalMonitorForEvents"))
        XCTAssertFalse(source.contains("NSEvent.addGlobalMonitorForEvents"))
        XCTAssertFalse(source.contains("NWPathMonitor("))
        XCTAssertTrue(source.contains("#if DEBUG || STORAGE_CLEANER_BETA\n@MainActor\nprivate func logControlPaletteEvent"))
        XCTAssertTrue(source.contains("PerformanceTelemetry.logger.notice(\"ControlPaletteTrace"))
        for event in ["button-entry", "hover-button-entry", "present-begin", "orderFront-before", "orderFront-after", "dismiss reason="] {
            XCTAssertTrue(source.contains(event), "The diagnostic build must identify \(event)")
        }
    }

    func testHoverAnchorUsesTheVisibleButtonHitRegion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root
                .appendingPathComponent("Sources/StorageCleanerMac/Support/ControlPaletteCoordinator.swift"),
            encoding: .utf8
        )
        let hoverAnchor = try XCTUnwrap(
            source.components(separatedBy: "struct ControlPaletteHoverAnchor").last
        )

        XCTAssertTrue(hoverAnchor.contains(".onContinuousHover"))
        XCTAssertTrue(hoverAnchor.contains("guard isHovered != hovering else { return }"))
        XCTAssertFalse(hoverAnchor.contains("onHoverChanged: hoverChanged"))
    }

    func testPaletteGeometryOpenPathStaysBelowInteractionBudget() {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 400, width: 304, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )
        let started = DispatchTime.now().uptimeNanoseconds

        coordinator.toggle(
            .fan,
            anchorScreenRect: NSRect(x: 690, y: 560, width: 72, height: 72),
            parentWindow: parent
        )

        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000
        XCTAssertLessThan(elapsedMilliseconds, 100)
    }

    func testSwitchingKindReusesPanelAndOnlyOutsideClickDismisses() {
        let parent = NSPanel(
            contentRect: NSRect(x: 400, y: 300, width: 304, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200),
            presentsPanelOnShow: false
        )
        let identity = ObjectIdentifier(coordinator.panel)
        let fanAnchor = NSRect(x: 590, y: 500, width: 72, height: 72)
        let powerAnchor = NSRect(x: 420, y: 330, width: 260, height: 46)

        coordinator.toggle(.fan, anchorScreenRect: fanAnchor, parentWindow: parent)
        coordinator.toggle(.power, anchorScreenRect: powerAnchor, parentWindow: parent)

        XCTAssertEqual(coordinator.state.kind, .power)
        XCTAssertEqual(ObjectIdentifier(coordinator.panel), identity)
        XCTAssertFalse(coordinator.handleMouseDown(
            sourceWindow: parent,
            screenLocation: NSPoint(x: powerAnchor.midX, y: powerAnchor.midY)
        ))
        XCTAssertTrue(coordinator.isPresented)

        XCTAssertTrue(coordinator.handleMouseDown(
            sourceWindow: parent,
            screenLocation: NSPoint(x: parent.frame.minX + 5, y: parent.frame.maxY - 5)
        ))
        XCTAssertFalse(coordinator.isPresented)
    }

    func testEscapeAndParentMovementKeepPaletteLifecycleBounded() {
        let parent = NSPanel(
            contentRect: NSRect(x: 500, y: 400, width: 304, height: 553),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let coordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: NSRect(x: 0, y: 0, width: 3_000, height: 2_000),
            presentsPanelOnShow: false
        )
        coordinator.toggle(
            .fan,
            anchorScreenRect: NSRect(x: 650, y: 600, width: 72, height: 72),
            parentWindow: parent
        )
        let initialOrigin = coordinator.panel.frame.origin

        parent.setFrameOrigin(NSPoint(x: 620, y: 480))
        coordinator.parentWindowDidMove()

        XCTAssertEqual(coordinator.panel.frame.minX - initialOrigin.x, 120, accuracy: 0.001)
        XCTAssertEqual(coordinator.panel.frame.minY - initialOrigin.y, 80, accuracy: 0.001)
        XCTAssertTrue(coordinator.handleEscape(sourceWindow: parent))
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(coordinator.handleEscape(sourceWindow: parent))
    }

    func testUnsynchronizedManualPlanMapsEachFanIndependently() throws {
        let readings = [
            SystemFanReading(
                index: 0,
                actualRPM: 3_000,
                minimumRPM: 1_200,
                maximumRPM: 6_000,
                targetRPM: 3_000
            ),
            SystemFanReading(
                index: 1,
                actualRPM: 3_500,
                minimumRPM: 1_500,
                maximumRPM: 7_500,
                targetRPM: 3_500
            ),
        ]
        let plan = try XCTUnwrap(FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0.5,
            manualFractionByFan: [0: 0, 1: 1],
            synchronizesManualFans: false,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: readings,
            temperatureReadings: nil
        ))

        XCTAssertEqual(plan.targetRPMByFan, [0: 1_200, 1: 7_500])
        XCTAssertTrue(plan.automaticFanIDs.isEmpty)
    }

    func testRequestedFanModeIsSeparateFromConfirmedReadback() async {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = TestPreferenceDomain.open(suiteName: suite)!
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let gate = FanControlReplyGate()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                await gate.reply(for: request)
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )

        let selection = Task { @MainActor in
            await coordinator.selectMode(.manual)
        }
        await gate.waitUntilPending()

        XCTAssertEqual(coordinator.requestedMode, .manual)
        XCTAssertNil(coordinator.observedMode)

        await gate.resume()
        await selection.value

        XCTAssertNil(coordinator.requestedMode)
        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertNil(coordinator.observedMode)
    }

    /// D152: iStat labels each slider with its fan's name, so the sliders
    /// carry the full hardware names (was FanTargetPickerPresentation's short
    /// "Fan 1" button title beside the full name in its menu).
    func testCompactFanNamesMapShortButtonsToFullHardwareNames() {
        let longNames = [
            "Optical Drive Cooling Fan With An Extended Hardware Name",
            "Power Supply Exhaust Fan With Another Extended Hardware Name",
        ]
        for usesChinese in [false, true] {
            let readings = longNames.enumerated().map { index, name in
                SystemFanReading(index: index,
                    identity: usesChinese ? (index == 0 ? .left : .right) : .named(name),
                    actualRPM: 2_800, minimumRPM: 1_200, maximumRPM: 5_400, targetRPM: 2_800)
            }
            let sliders = FanManualSliderList.sliders(readings: readings, synchronizes: false)
            XCTAssertEqual(sliders.map(\.fanID), [0, 1])
            XCTAssertEqual(sliders.map(\.title), readings.map(\.displayName))
            if !usesChinese {
                XCTAssertEqual(sliders.map(\.title), longNames)
            }
        }
    }

    /// D152: no fan picker; iStat shows a slider per fan under its name
    /// (was a fixed 80 pt Menu with an inline Picker bound to the selected
    /// fan, the short title on its button and the full names in the menu).
    func testCompactFanMenuUsesBoundPickerForNativeSelection() throws {
        let viewSource = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/FanControlInlineControls.swift")
        XCTAssertFalse(viewSource.contains("compactTargetFanMenu"))
        XCTAssertFalse(viewSource.contains("Picker("))
        XCTAssertFalse(viewSource.contains("FanTargetPickerPresentation"))
        let list = try MiniWindowLogicFixtures.section(viewSource,
            from: "struct FanManualSliderList: View {\n", to: "    var body: some View {")
        XCTAssertTrue(list.contains("if synchronizes || readings.count < 2 {"))
        XCTAssertTrue(list.contains("return readings.map { Slider(fanID: $0.index, title: $0.displayName) }"))
    }

    func testFanLayoutFixturePausesAuxiliaryMonitoringBeforeSuspending() throws {
        let testSource = try MiniWindowLogicFixtures.source("Tests/StorageCleanerMacTests/ControlPaletteTests.swift")
        let fixture = try MiniWindowLogicFixtures.section(testSource,
            from: "    private func checkFanPaletteLayout(\n",
            to: "    private func checkCompactTargetFanNames(")
        XCTAssertEqual(fixture.components(separatedBy: "let store = try ScanStore.makeForTests(").count - 1, 1)
        XCTAssertTrue(fixture.contains("let store = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults, cleanReportLoader: { [] })\n                    store.menuBarAuxiliaryMonitorState.setPaused(true)"),
            "D48: pause synchronously on the next line after construction, before yielding to system notifications")
        let afterConstruction = try XCTUnwrap(fixture.components(separatedBy:
            "let store = try ScanStore.makeForTests(").dropFirst().first)
        let beforeFirstAwait = try XCTUnwrap(afterConstruction.components(separatedBy: "await ").first)
        XCTAssertTrue(beforeFirstAwait.contains("store.menuBarAuxiliaryMonitorState.setPaused(true)"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    func testNativeSegmentsFillContentWidthAndOnlySubmitEnabledActions() async throws {
        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
        }
        let labels = [
            ["自动", "低功耗", "高功率"],
            ["Automatic", "Low Power", "High Power"],
            ["80%", "85%", "90%", "95%", "100%"],
        ]
        for (caseIndex, titles) in labels.enumerated() {
            for width: CGFloat in [210, 248] {
                let state = MiniWindowSegmentTestSelection()
                let picker = MiniWindowSegmentedPicker(
                    title: "Energy Mode",
                    selection: Binding(get: { state.selection }, set: {
                        state.selection = $0
                        state.submissions += 1
                    }),
                    options: Array(titles.indices), label: { titles[$0] }
                ).frame(width: width).padding(8)
                    .environment(\.colorScheme, caseIndex == 1 ? .light : .dark)
                let host = NSHostingView(rootView: AnyView(picker.disabled(false)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 16, height: 40),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                let fits = await eventually {
                    host.layoutSubtreeIfNeeded()
                    return segmentedControl(in: host).map { abs($0.frame.width - width) < 0.5 } ?? false
                }
                XCTAssertTrue(fits, "The native control itself must fill the assigned width")
                let control = try XCTUnwrap(segmentedControl(in: host))
                XCTAssertEqual(control.segmentDistribution, .fillEqually)
                XCTAssertEqual(control.segmentCount, titles.count)
                XCTAssertEqual(control.selectedSegment, 1)
                XCTAssertEqual(control.appearance?.name, caseIndex == 1 ? .aqua : .darkAqua)
                XCTAssertEqual(state.submissions, 0, "Rendering must not submit a setting")
                control.selectedSegment = titles.count - 1
                control.sendAction(try XCTUnwrap(control.action), to: control.target)
                XCTAssertEqual(state.selection, titles.count - 1)
                XCTAssertEqual(state.submissions, 1)
                host.rootView = AnyView(picker.disabled(true))
                let disabled = await eventually {
                    host.layoutSubtreeIfNeeded()
                    return segmentedControl(in: host)?.isEnabled == false
                }
                XCTAssertTrue(disabled)
                let disabledControl = try XCTUnwrap(segmentedControl(in: host))
                disabledControl.selectedSegment = 0
                disabledControl.sendAction(try XCTUnwrap(disabledControl.action), to: disabledControl.target)
                XCTAssertEqual(state.submissions, 1, "Disabled actions must not submit a setting")
                window.contentView = nil
            }
        }
    }

    func testFanPaletteNativeLayoutMatrixFitsAndKeepsHardwareReadOnly() async throws {
        let states: [MiniWindowDemoData.HardwareControlDemoState] = [
            .fanAutomatic, .fanManual65, .curveActive, .fanless,
            .helperNotRegistered, .fanReadOnly, .thermalCritical, .fanReadbackFailed,
        ]
        try await checkFanPaletteLayout(states: states)
    }

    /// 手动模式的 280 pt 预算也覆盖带同步开关的双风扇。
    func testDualFanManualPaletteFitsTheSameHeightBudget() async throws {
        try await checkFanPaletteLayout(states: [.dualFanManual])
    }

    func testUnsynchronizedDualFanManualPaletteFitsWithHeadroom() async throws {
        try await checkFanPaletteLayout(states: [.dualFanManual], synchronized: false)
    }

    func testLongFanNamesUseShortCompactButtonsAndFullMenuNames() async throws {
        try await checkFanPaletteLayout(states: [.dualFanManual], synchronized: false, checksLongFanNames: true)
    }

    private func checkFanPaletteLayout(
        states: [MiniWindowDemoData.HardwareControlDemoState],
        synchronized: Bool = true,
        checksLongFanNames: Bool = false
    ) async throws {
        // D48：这组布局测试的偏好域由 TestPreferenceDomain 建在临时目录。
        let artifactDirectory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_LAYOUT_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let artifactDirectory {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        }
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }
        for language in [AppLanguage.zhHans, .english] {
            var arguments = previousArguments
            arguments[L10n.languageDefaultsKey] = language.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            XCTAssertEqual(L10n.usesChinese, language == .zhHans)
            if checksLongFanNames {
                try await checkCompactTargetFanNames(language: language)
            }
            for dark in [false, true] {
                for state in states {
                    let suite = TestPreferenceDomain.makeSuite()
                    let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
                    defer { TestPreferenceDomain.cleanup(suiteName: suite) }
                    let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
                    let snapshot = fixtureSnapshot(profile)
                    // D152: a fixture refuses Sync like every write, so the
                    // stored preference sets it (was setManualFansSynchronized
                    // on the fixture).
                    if state == .dualFanManual {
                        defaults.set(synchronized, forKey: FanControlPreferences.manualSyncKey)
                    }
                    let fanControl = FanControlCoordinator.makeReadOnlyFixture(
                        defaults: defaults, profile: profile, snapshot: snapshot)
                    if state == .dualFanManual {
                        XCTAssertEqual(fanControl.synchronizesManualFans, synchronized)
                    }
                    let store = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults, cleanReportLoader: { [] })
                    store.menuBarAuxiliaryMonitorState.setPaused(true)
                    store.menuBarMonitorState.update(snapshot)
                    let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
                    let parent = NSPanel(contentRect: NSRect(x: 650, y: 80, width: 312, height: 580),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    let visible = NSRect(x: 0, y: 0, width: 1280, height: 760)
                    let coordinator = ControlPaletteCoordinator(fixedVisibleFrame: visible, presentsPanelOnShow: false) { presentation in
                        AnyView(ControlPaletteRootView(presentation: presentation, store: store,
                            computerHealthStore: health, fanControl: fanControl)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.displayScale, 2))
                    }
                    defer { coordinator.teardown() }
                    let host = try XCTUnwrap(coordinator.panel.contentView as? NSHostingView<AnyView>)
                    coordinator.toggle(.fan, anchorScreenRect: NSRect(x: 650, y: 120, width: 280, height: 24), parentWindow: parent)
                    // D152: one page, no expanded details (was the compact
                    // page, then setFanControlsExpanded(true) growing it).
                    let fits = await eventually {
                        host.layoutSubtreeIfNeeded()
                        coordinator.panel.displayIfNeeded()
                        guard let measured = coordinator.state.measuredContentHeight,
                              coordinator.state.hasNaturalContentMeasurement else { return false }
                        return abs(coordinator.panel.frame.height - measured) < 0.5
                    }
                    XCTAssertTrue(fits, "\(state) must fit its measured content")
                    let height = coordinator.state.measuredContentHeight
                    if state == .fanAutomatic {
                        XCTAssertLessThanOrEqual(height ?? .infinity, 230,
                            "D152: the four sections with one fan stay within the compact automatic budget")
                    } else if state == .fanManual65 || state == .dualFanManual {
                        XCTAssertLessThanOrEqual(height ?? .infinity, 280,
                            "Manual mode should fit its sliders without opening a tall inspector")
                        if state == .dualFanManual {
                            XCTAssertLessThanOrEqual(height ?? .infinity, 276,
                                "Both synchronization states need at least 4 pt of headroom")
                        }
                    }
                    print("风扇高度：\(state.rawValue) sync=\(synchronized) \(language.rawValue) \(dark ? "深色" : "浅色") \(height ?? .infinity) pt")
                    XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.fanSize.width)
                    XCTAssertTrue(visible.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
                    XCTAssertLessThanOrEqual(host.fittingSize.width, ControlPaletteMetrics.fanSize.width + 0.5)
                    XCTAssertNil(fanControl.requestedMode)
                    XCTAssertFalse(fanControl.isApplying)
                    XCTAssertEqual(fanControl.observedMode, profile.observedMode)
                    if let artifactDirectory {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(language.rawValue)-\(state.rawValue)-sync-\(synchronized)-\(dark ? "dark" : "light").png"
                        try png.write(to: artifactDirectory.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    private func checkCompactTargetFanNames(language: AppLanguage) async throws {
        // Own AppKit initialization even when this is the only selected test.
        #if DEBUG
        let applicationWasInitialized = NSApp != nil
        let initialFailureCount = testRun?.failureCount ?? 0
        var layoutDiagnostics: [Data] = []
        defer {
            if (testRun?.failureCount ?? 0) > initialFailureCount {
                for evidence in layoutDiagnostics {
                    FileHandle.standardError.write(evidence)
                }
            }
        }
        #endif
        _ = NSApplication.shared
        let longNames = [
            "Optical Drive Cooling Fan With An Extended Hardware Name",
            "Power Supply Exhaust Fan With Another Extended Hardware Name",
        ]
        // Pure name mapping is tested outside the fixture's DEBUG/BETA guard.
        XCTAssertGreaterThan((longNames[0] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width, 80)
        #if DEBUG
        let readings = longNames.enumerated().map { index, name in
            SystemFanReading(index: index, identity: language == .english ? .named(name) : (index == 0 ? .left : .right),
                actualRPM: 2_800, minimumRPM: 1_200, maximumRPM: 5_400, targetRPM: 2_800)
        }
        let base = MiniWindowDemoData.fixture.snapshot
        let telemetry = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
            generatedAt: base.generatedAt, metrics: base.metrics, networkThroughput: nil,
            thermalState: .nominal, fanReadings: readings,
            temperatureReadings: [], sensorAvailability: base.sensorAvailability))
        let states = ProcessInfo.processInfo.environment["STORAGE_CLEANER_FAN_SYNC_ORDER"] == "reversed"
            ? [false, true] : [true, false]
        // D152: the palette itself at its column width, with a coordinator in
        // automatic mode so Sync only stores (was the slider list bound to a
        // draft at 260 pt with the 80 pt target-fan menu).
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        defaults.set(states[0], forKey: FanControlPreferences.manualSyncKey)
        let fanControl = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: { _ in XCTFail("A layout test must not reach the helper"); throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled },
            serviceRegistrar: { XCTFail("A layout test must never register Helper") })
        defer { fanControl.disconnectForTermination() }
        let recorder = ControlPaletteFanFrameRecorder()
        let width = ControlPaletteMetrics.fanSize.width - 2 * GeekPanelLayout.contentPadding
        let size = CGSize(width: width, height: 320)
        // Both samples must belong to one fixed viewport and coordinate space.
        // The production palette also disables automatic hosting size options.
        let host = NSHostingView(rootView: ControlPaletteFanLayoutContent(
            fanControl: fanControl, telemetry: telemetry, width: width, recorder: recorder)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.locale, L10n.locale)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 2))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        var syncFrames: [CGRect] = []
        for synchronized in states {
            recorder.frames = [:]
            fanControl.setManualFansSynchronized(synchronized)
            XCTAssertEqual(fanControl.synchronizesManualFans, synchronized)
            let expected = synchronized ? ["fan.manual.slider.-1"] : ["fan.manual.slider.0", "fan.manual.slider.1"]
            let absent = synchronized ? ["fan.manual.slider.0", "fan.manual.slider.1"] : ["fan.manual.slider.-1"]
            var lastFrames: [String: CGRect]?
            var stableSamples = 0
            let measured = await eventually {
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                // Never accept the first merely nonempty preference delivery.
                // Stability is independent of the later position expectations.
                guard let root = recorder.frames["fan.palette.fixture"],
                      abs(root.width - width) <= 0.5,
                      abs(root.minX) <= 0.5, abs(root.minY) <= 0.5,
                      host.bounds.size == size, host.frame.size == size,
                      let sync = recorder.frames["fan.manual.sync"],
                      abs(sync.height - GeekIStatTextSectionGeometry.rowHeight) <= 0.5,
                      root.insetBy(dx: -0.5, dy: -0.5).contains(sync),
                      expected.allSatisfy({ id in
                          recorder.frames[id].map { root.insetBy(dx: -0.5, dy: -0.5).contains($0) } ?? false
                      }),
                      absent.allSatisfy({ recorder.frames[$0] == nil }) else {
                    lastFrames = nil; stableSamples = 0
                    return false
                }
                let current = recorder.frames
                stableSamples = current == lastFrames ? stableSamples + 1 : 0
                lastFrames = current
                return stableSamples >= 2
            }
            let frames = recorder.frames
            let rect: (CGRect) -> [Double] = { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
            let evidence: [String: Any] = [
                "language": language.rawValue, "synchronized": synchronized, "order": states,
                "applicationWasInitialized": applicationWasInitialized, "measured": measured,
                "appLanguage": L10n.appLanguage.rawValue, "usesChinese": L10n.usesChinese,
                "locale": L10n.locale.identifier, "systemLocale": Locale.current.identifier,
                "preferredLanguages": Locale.preferredLanguages,
                "fontName": NSFont.systemFont(ofSize: 11).fontName,
                "fontSize": Double(NSFont.systemFont(ofSize: 11).pointSize),
                "appearance": host.effectiveAppearance.name.rawValue,
                "applicationWindowCount": NSApp?.windows.count ?? 0,
                "hostFrame": rect(host.frame), "hostBounds": rect(host.bounds),
                "windowContent": rect(window.contentLayoutRect), "stableSamples": stableSamples,
                "frames": frames.mapValues(rect),
            ]
            let evidenceData = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            layoutDiagnostics.append(Data(("FAN_SYNC_LAYOUT " + String(decoding: evidenceData, as: UTF8.self) + "\n").utf8))
            XCTAssertTrue(measured)
            syncFrames.append(try XCTUnwrap(frames["fan.manual.sync"]))
            let section = try XCTUnwrap(frames["fan.section.manual"])
            let sliders = try expected.map { try XCTUnwrap(frames[$0]) }
            for slider in sliders {
                XCTAssertEqual(slider.height, FanControlSliderGeometry.height, accuracy: 0.5)
                XCTAssertEqual(slider.width, section.width, accuracy: 0.5)
            }
            if !synchronized {
                XCTAssertEqual(sliders[1].minY - sliders[0].maxY, FanControlSliderGeometry.spacing, accuracy: 0.5)
                // The full names stay on the sliders and are cut inside the
                // label's W − 16 instead of widening the page.
                XCTAssertEqual(FanManualSliderList.sliders(readings: readings, synchronizes: false).map(\.title),
                               readings.map(\.displayName))
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5)
            }
        }
        XCTAssertEqual(syncFrames[0].maxX, syncFrames[1].maxX, accuracy: 0.5)
        XCTAssertEqual(syncFrames[0].minY, syncFrames[1].minY, accuracy: 0.5)
        #endif
    }
    #endif

    /// 文档没有电源高度预算；测生产内容自然高度，锁定面板跟随测量且不裁切。
    /// 仅 SwiftUI 内容与假闭包，不创建 ScanStore、不调用真实充电或健康服务。
    func testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let manual90 = try XCTUnwrap(BatteryChargeTarget(rawValue: 90))
        let targets: [BatteryChargeTarget] = [.protected, manual90, .full]
        let cases: [(String, BatteryChargeLimitState?, BatteryPowerSource)] = [
            ("optimized80", BatteryChargeLimitState(target: .full, availableTargets: targets,
                effectiveLimit: 80, source: .optimized), .acPower),
            ("optimized80-battery", BatteryChargeLimitState(target: .full, availableTargets: targets,
                effectiveLimit: 80, source: .optimized), .batteryPower),
            ("manual80", BatteryChargeLimitState(target: .protected, availableTargets: targets,
                effectiveLimit: 80, source: .manual), .acPower),
            ("combined80", BatteryChargeLimitState(target: manual90, availableTargets: targets,
                effectiveLimit: 80, source: .manualAndOptimized), .acPower),
            ("system-only-optimized80", BatteryChargeLimitState(target: .full, availableTargets: [],
                effectiveLimit: 80, source: .optimized), .acPower),
            ("smart-paused100", BatteryChargeLimitState(target: .full, availableTargets: targets,
                effectiveLimit: 100, source: .none, smartChargingTemporarilyDisabled: true), .acPower),
            ("manual-lifted100", BatteryChargeLimitState(target: .protected, availableTargets: targets,
                effectiveLimit: 100, source: .manual, manualLimitTemporarilyDisabled: true), .acPower),
            ("many-segments", BatteryChargeLimitState(target: .protected,
                availableTargets: [70, 75, 80, 85, 90, 95, 100].compactMap(BatteryChargeTarget.init(rawValue:)),
                effectiveLimit: 80, source: .manual), .acPower),
            ("nil", nil, .acPower),
        ]
        let artifactDirectory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_LAYOUT_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let artifactDirectory {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            XCTAssertEqual(L10n.usesChinese, language == .zhHans)
            for dark in [false, true] {
                for (name, state, powerSource) in cases {
                    if let state, !state.availableTargets.isEmpty {
                        XCTAssertTrue(state.availableTargets.contains(state.target), "\(name) 的手动目标须在选项内")
                    }
                    let visible = NSRect(x: 0, y: 0, width: 1280, height: 760)
                    let parent = NSPanel(contentRect: NSRect(x: 400, y: 200, width: 304, height: 553),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    let coordinator = ControlPaletteCoordinator(fixedVisibleFrame: visible, presentsPanelOnShow: false) { presentation in
                        // 与 ControlPaletteRootView 一样观察 presentation：切到电源页后重新测量。
                        AnyView(ControlPaletteObservingTestContent(presentation: presentation, content: AnyView(MetricPanelShell {
                            VStack(alignment: .leading, spacing: 0) {
                                GeekEnergyModeHoverDetail(
                                    batteryMode: .automatic, batterySupportedModes: [.lowPower, .automatic, .highPower],
                                    adapterMode: .automatic, adapterSupportedModes: [.lowPower, .automatic, .highPower],
                                    powerSource: powerSource, isCharging: false,
                                    showsChargeTargetSetting: true, showsFullChargeAction: powerSource == .acPower,
                                    chargeLimitState: state, batteryPowerWatts: 0,
                                    adapterPowerWatts: powerSource == .acPower ? 94 : nil, adjustmentState: .idle,
                                    controlsEnabled: true, chargeLimitControlsEnabled: true,
                                    onChargeToFull: { XCTFail("布局测试不得写入"); return .unsupported },
                                    onSetChargeTarget: { _ in XCTFail("布局测试不得改上限"); return .unsupported },
                                    onOpenBatterySettings: {}, onChangeMode: { _, _ in XCTFail("不得改能源模式") }
                                )
                            }
                            .controlSize(.small)
                            .padding(GeekPanelLayout.contentPadding)
                        }
                        .modifier(PanelMetricColorEnvironment())
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.displayScale, 2))))
                    }
                    defer { coordinator.teardown() }
                    coordinator.toggle(.power, anchorScreenRect: NSRect(x: 420, y: 520, width: 264, height: 25), parentWindow: parent)
                    let host = try XCTUnwrap(coordinator.panel.contentView as? NSHostingView<AnyView>)
                    let fits = await eventually {
                        // 与风扇调板的测量测试相同：标记需要布局并显示一次，原生测量才会上报。
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                        coordinator.panel.displayIfNeeded()
                        guard coordinator.state.hasNaturalContentMeasurement,
                              let height = coordinator.state.measuredContentHeight else { return false }
                        return abs(coordinator.panel.frame.height - height) < 0.5
                    }
                    XCTAssertTrue(fits, "\(language.rawValue) \(name) 的自然高度须传给面板")
                    let height = try XCTUnwrap(coordinator.state.measuredContentHeight)
                    XCTAssertGreaterThan(height, 0)
                    XCTAssertEqual(coordinator.panel.frame.height, height, accuracy: 0.5)
                    XCTAssertEqual(coordinator.panel.frame.width, ControlPaletteMetrics.powerSize.width)
                    XCTAssertLessThanOrEqual(host.fittingSize.width, ControlPaletteMetrics.powerSize.width + 0.5)
                    XCTAssertTrue(visible.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
                    print("电源自然高度：\(language.rawValue) \(dark ? "深色" : "浅色") \(name) \(height) pt")
                    if let artifactDirectory {
                        host.displayIfNeeded()
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: artifactDirectory.appendingPathComponent(
                            "power-r2-\(language.rawValue)-\(dark ? "dark" : "light")-\(name).png"))
                    }
                }
            }
        }
    }

    private func eventually(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class MiniWindowSegmentTestSelection {
    var selection = 1
    var submissions = 0
}

@MainActor
private final class ControlPaletteTestLayout: ObservableObject {
    @Published var height: CGFloat = 248
}

private struct ControlPaletteObservingTestContent: View {
    @ObservedObject var presentation: ControlPalettePresentationState
    let content: AnyView

    var body: some View {
        content.controlPaletteContentLayout(presentation)
    }
}

@MainActor
private final class ControlPaletteFanFrameRecorder {
    var frames: [String: CGRect] = [:]
}

#if DEBUG
/// D152: the fan palette at its column width with a probe on the whole page
/// (was the slider list bound to a draft in `ControlPaletteFanLayoutDraft`).
@MainActor
private struct ControlPaletteFanLayoutContent: View {
    @ObservedObject var fanControl: FanControlCoordinator
    let telemetry: FanTelemetryState
    let width: CGFloat
    let recorder: ControlPaletteFanFrameRecorder
    @StateObject private var presentation = ControlPalettePresentationState()

    var body: some View {
        let synchronized = fanControl.synchronizesManualFans
        return FanControlPaletteView(presentation: presentation, fanControl: fanControl,
                                     telemetry: telemetry, thermalState: .nominal)
            .frame(width: width)
            .layoutProbe("fan.palette.fixture")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in
                    // Ignore a queued delivery for the state we just replaced.
                    guard fanControl.synchronizesManualFans == synchronized else { return }
                    recorder.frames = frames
                }
            }
    }
}
#endif

private struct ControlPaletteTestContent: View {
    @ObservedObject var presentation: ControlPalettePresentationState
    @ObservedObject var layout: ControlPaletteTestLayout

    var body: some View {
        Color.clear
            .frame(height: layout.height)
            .controlPaletteContentLayout(presentation)
    }
}

private struct ControlPaletteUnusedHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        XCTFail("A fan layout test must not start health sampling")
        throw CancellationError()
    }
}

private actor FanControlReplyGate {
    private var pending:
        (request: FanControlHelperRequest, continuation: CheckedContinuation<FanControlHelperReply, Never>)?

    func reply(for request: FanControlHelperRequest) async -> FanControlHelperReply {
        await withCheckedContinuation { continuation in
            pending = (request, continuation)
        }
    }

    func waitUntilPending() async {
        while pending == nil {
            await Task.yield()
        }
    }

    func resume() {
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(returning: FanControlHelperReply(
            operation: pending.request.operation,
            success: true,
            message: "verified",
            appliedTargetRPMByFan: [:]
        ))
    }
}
