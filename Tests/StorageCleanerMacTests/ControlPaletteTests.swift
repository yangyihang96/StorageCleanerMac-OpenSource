import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class ControlPaletteTests: XCTestCase {
    #if DEBUG || STORAGE_CLEANER_BETA
    func testReadOnlyFixturePublishesAutomaticReadbackAndPreservesUnknownMode() throws {
        for state in [MiniWindowDemoData.HardwareControlDemoState.dualFan, .helperEnabled] {
            let suite = "ControlPaletteTests.Fixture.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
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
            let suite = "ControlPaletteTests.FixtureDenial.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
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
        XCTAssertTrue(coordinator.contains("private func send(_ request: FanControlHelperRequest) async throws -> FanControlHelperReply {\n        guard !isDataOnlyFixture else { throw CancellationError() }"))
        let controller = try source("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift")
        XCTAssertTrue(controller.contains("if MiniWindowDemoData.isEnabled {\n            paletteFanControl = FanControlCoordinator.makeReadOnlyFixture("))
        XCTAssertTrue(controller.contains("fanControl: paletteFanControl"))
        XCTAssertTrue(controller.contains("paletteFanControl = .shared"))
        let routes = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(routes.contains("return FanControlCoordinator.makeReadOnlyFixture("))
        XCTAssertFalse(routes.contains("height: isExpanded ? 430 : 250"))
        XCTAssertTrue(routes.contains(".fixedSize(horizontal: false, vertical: true)"))
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(palette.contains("controlsEnabled: fanControl.helperState == .enabled && !fanControl.isDataOnlyFixture"))
        XCTAssertTrue(palette.contains("if fanControl.isDataOnlyFixture { return L10n.text(\"FIXTURE"))
        XCTAssertTrue(palette.contains("draft.selectMode(mode)"))
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
        XCTAssertEqual(FanManualSliderList.actualRPM(fanID: nil, telemetry: telemetry), 1_200)
        XCTAssertEqual(FanManualSliderList.actualRPM(fanID: 0, telemetry: telemetry), 0)
        XCTAssertEqual(FanManualSliderList.actualRPM(fanID: 1, telemetry: telemetry), 2_400)
        XCTAssertNil(FanManualSliderList.actualRPM(fanID: 2, telemetry: telemetry))
    }

    func testFanDraftSelectionSliderSyncPresetAndCancelNeverSubmit() throws {
        let suite = "ControlPaletteTests.Draft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [FanControlHelperRequest] = []
        var registrations = 0
        let coordinator = FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: { request in requests.append(request); throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }, serviceRegistrar: { registrations += 1 }
        )
        defer { coordinator.disconnectForTermination() }
        let telemetry = draftTelemetry()
        let originalReadings = telemetry.readings
        let persistedBefore = defaults.dictionaryRepresentation().mapValues { String(describing: $0) }
        var draft = FanControlDraft(telemetry: telemetry, observedMode: nil, synchronizesFans: true)
        let original = draft.configuration
        draft.selectMode(.manual)
        for percentage in 0...100 { draft.setPercentage(Double(percentage), fanID: nil) }
        draft.setSynchronized(false)
        draft.setTargetRPM(1_750, fanID: 0, telemetry: telemetry)
        draft.setPercentage(75, fanID: 1)
        draft.setSynchronized(true)
        draft.selectMode(.customCurve)
        draft.selectMode(.systemAutomatic)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertNil(coordinator.requestedMode)
        XCTAssertEqual(telemetry.readings, originalReadings)
        draft.cancel()
        XCTAssertEqual(draft.configuration, original)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(defaults.dictionaryRepresentation().mapValues { String(describing: $0) }, persistedBefore)
    }

    func testManualDraftMapsPerFanRPMAndRejectsUnknownRanges() throws {
        let telemetry = draftTelemetry()
        var draft = FanControlDraft(telemetry: telemetry, observedMode: nil, synchronizesFans: false)
        draft.selectMode(.manual)
        draft.setTargetRPM(1_750, fanID: 0, telemetry: telemetry)
        draft.setTargetRPM(4_000, fanID: 1, telemetry: telemetry)
        XCTAssertEqual(draft.percentage(for: 0), 25)
        XCTAssertEqual(draft.percentage(for: 1), 50)
        XCTAssertEqual(draft.targetRPM(fanID: 0, telemetry: telemetry), 1_750)
        XCTAssertEqual(draft.targetRPM(fanID: 1, telemetry: telemetry), 4_000)
        XCTAssertEqual(FanManualSliderList.actualRPM(fanID: 0, telemetry: telemetry), 0)
        draft.setTargetRPM(Int.min, fanID: 0, telemetry: telemetry)
        XCTAssertEqual(draft.targetRPM(fanID: 0, telemetry: telemetry), 1_000)
        draft.setTargetRPM(Int.max, fanID: 0, telemetry: telemetry)
        XCTAssertEqual(draft.targetRPM(fanID: 0, telemetry: telemetry), 4_000)
        XCTAssertFalse(draft.matchesReadback(mode: nil, fractions: [0: 1, 1: 0.5]))
        XCTAssertFalse(draft.matchesReadback(mode: .manual, fractions: [0: 0.5, 1: 0.5]))
        XCTAssertTrue(draft.matchesReadback(mode: .manual, fractions: [0: 1, 1: 0.5]))
        for readings in [
            [SystemFanReading(index: 0, actualRPM: 0, minimumRPM: nil, maximumRPM: nil, targetRPM: nil)],
            [telemetry.readings[0], telemetry.readings[0]],
        ] {
            let unavailable = FanTelemetryState.resolve(snapshot: SystemMonitorSnapshot(
                generatedAt: Date(), metrics: [], networkThroughput: nil, fanReadings: readings
            ))
            var draft = FanControlDraft(telemetry: unavailable, observedMode: nil, synchronizesFans: true)
            draft.setPercentage(100, fanID: nil)
            XCTAssertNil(draft.targetRPM(fanID: nil, telemetry: unavailable))
        }
    }

    func testManualDraftOnlyExplicitSubmitUsesTheExistingVerifiedRequestChain() async throws {
        let suite = "ControlPaletteTests.DraftApply.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
            serviceRegistrar: { XCTFail("Explicit draft submission must not register Helper") }
        )
        defer { coordinator.disconnectForTermination() }
        let snapshot = SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: [SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 4_000, targetRPM: 2_000)])
        coordinator.process(snapshot: snapshot)
        let telemetry = FanTelemetryState.resolve(snapshot: snapshot)
        var draft = FanControlDraft(telemetry: telemetry, observedMode: nil, synchronizesFans: true)
        draft.selectMode(.manual)
        draft.setTargetRPM(2_500, fanID: nil, telemetry: telemetry)
        XCTAssertTrue(requests.isEmpty)
        let submitted = await draft.submit(to: coordinator, telemetry: telemetry, thermalState: .nominal)
        XCTAssertTrue(submitted)
        let confirmed = await eventually { coordinator.observedMode == .manual && !coordinator.isApplying }
        XCTAssertTrue(confirmed)
        XCTAssertTrue(requests.contains { $0.operation == .apply })
        XCTAssertTrue(requests.allSatisfy { [.ping, .apply, .renewFanControlLease].contains($0.operation) })
        XCTAssertEqual(coordinator.latestFanReadings.first?.actualRPM, 2_000)
    }

    func testSameRPMDraftWaitsForSettledReadbackAndSurvivesFailure() async throws {
        for succeeds in [false, true] {
            let suite = "ControlPaletteTests.SettledDraft.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var now = Date()
            var holdsWrites = false
            var pending: (FanControlHelperRequest, CheckedContinuation<FanControlHelperReply, Never>)?
            let coordinator = FanControlCoordinator(
                defaults: defaults, helperStatusOverride: .enabled, isHelperReachable: true,
                now: { now },
                requestSender: { request in
                    if holdsWrites && [.apply, .renewFanControlLease].contains(request.operation) {
                        return await withCheckedContinuation { pending = (request, $0) }
                    }
                    return FanControlHelperReply(operation: request.operation, success: true,
                        message: "verified", appliedTargetRPMByFan: request.operation == .renewFanControlLease
                            ? [0: 2_500] : request.targetRPMByFan)
                },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .enabled },
                serviceRegistrar: { XCTFail("A draft confirmation test must not register Helper") }
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
            let telemetry = FanTelemetryState.resolve(snapshot: snapshot)
            var draft = FanControlDraft(telemetry: telemetry, observedMode: coordinator.observedMode,
                synchronizesFans: coordinator.synchronizesManualFans,
                confirmedFractions: coordinator.confirmedManualFractionByFan)
            draft.setSynchronized(!draft.synchronizesFans)
            let submitted = draft.configuration
            XCTAssertTrue(draft.hasChanges)
            XCTAssertTrue(draft.matchesReadback(mode: coordinator.observedMode,
                fractions: coordinator.confirmedManualFractionByFan), "Targets are deliberately identical to the old readback")
            XCTAssertFalse(FanControlPaletteView.confirmSubmittedDraft(&draft,
                submittedConfiguration: submitted, isSubmitting: true, fanControl: coordinator))

            // Renew the same targets through the injected transport. Its reply
            // remains pending while the previous confirmed mode/targets remain.
            now.addTimeInterval(FanControlSafetyPolicy.leaseRenewalInterval + 0.1)
            holdsWrites = true
            let accepted = await draft.submit(to: coordinator, telemetry: telemetry, thermalState: .nominal)
            XCTAssertTrue(accepted)
            let waiting = await eventually { pending != nil }
            XCTAssertTrue(waiting)
            XCTAssertTrue(coordinator.isApplying)
            XCTAssertFalse(FanControlPaletteView.confirmSubmittedDraft(&draft,
                submittedConfiguration: submitted, isSubmitting: false, fanControl: coordinator))
            XCTAssertTrue(draft.hasChanges)
            let reply = try XCTUnwrap(pending)
            pending = nil
            holdsWrites = false
            reply.1.resume(returning: FanControlHelperReply(operation: reply.0.operation,
                success: succeeds, message: succeeds ? "verified" : "rejected",
                appliedTargetRPMByFan: succeeds ? [0: 2_500] : [:]))
            let settled = await eventually { !coordinator.isApplying && !coordinator.isSwitchingMode }
            XCTAssertTrue(settled)
            XCTAssertEqual(FanControlPaletteView.confirmSubmittedDraft(&draft,
                submittedConfiguration: submitted, isSubmitting: false, fanControl: coordinator), succeeds)
            XCTAssertEqual(draft.hasChanges, !succeeds)
            XCTAssertEqual(coordinator.latestFanReadings.first?.actualRPM, succeeds ? 2_500 : nil)
        }
    }

    func testDraftSubmissionRejectsFixtureUnapprovedAndThermallyProtectedStates() async throws {
        let telemetry = draftTelemetry()
        #if DEBUG || STORAGE_CLEANER_BETA
        for state in [MiniWindowDemoData.HardwareControlDemoState.fanAutomatic, .fanReadOnly, .helperNotRegistered, .awaitingSystemApproval, .connectionInterrupted] {
            let suite = "ControlPaletteTests.DraftDenied.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
            let coordinator = FanControlCoordinator.makeReadOnlyFixture(defaults: defaults, profile: profile, snapshot: fixtureSnapshot(profile))
            var draft = FanControlDraft(telemetry: telemetry, observedMode: profile.observedMode, synchronizesFans: true)
            draft.selectMode(.manual)
            draft.setPercentage(75, fanID: nil)
            let submitted = await draft.submit(to: coordinator, telemetry: telemetry, thermalState: .nominal)
            XCTAssertFalse(submitted)
            XCTAssertEqual(coordinator.observedMode, profile.observedMode)
            XCTAssertNil(coordinator.requestedMode)
        }
        #endif
        for helper in [FanControlHelperStatus.notRegistered, .requiresApproval, .enabled] {
            let suite = "ControlPaletteTests.DraftGuard.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = FanControlCoordinator(defaults: defaults, helperStatusOverride: helper,
                isHelperReachable: helper == .enabled,
                requestSender: { _ in XCTFail("Blocked drafts cannot reach transport"); throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                serviceStatusProvider: { .notRegistered },
                serviceRegistrar: { XCTFail("Blocked drafts cannot register Helper") })
            defer { coordinator.disconnectForTermination() }
            var draft = FanControlDraft(telemetry: telemetry, observedMode: nil, synchronizesFans: true)
            draft.selectMode(.manual)
            let submitted = await draft.submit(to: coordinator, telemetry: telemetry,
                thermalState: helper == .enabled ? .critical : .nominal)
            XCTAssertFalse(submitted)
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
            size: ControlPaletteMetrics.fanCurveSize,
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
        XCTAssertEqual(ControlPaletteMetrics.gap, 4)
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

        coordinator.state.showFanCurveEditor()
        layout.height = 650
        let editorMeasured = await eventually {
            host.layoutSubtreeIfNeeded()
            return coordinator.state.measuredContentHeight == 650
                && coordinator.panel.frame.height == 650
                && coordinator.panel.frame.width == ControlPaletteMetrics.fanCurveSize.width
        }
        XCTAssertTrue(editorMeasured)
        XCTAssertTrue(visibleFrame.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.presentationCount, 1, "Changing content reuses the existing palette")

        coordinator.state.showFanControls()
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
    func testConfirmedAutomaticUsesShortNativeLayoutAndCancelledDraftNeverWrites() async throws {
        let suite = "ControlPaletteTests.AutomaticSummary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = MiniWindowDemoData.hardwareControlProfile(for: .fanAutomatic)
        let snapshot = fixtureSnapshot(profile)
        let fanControl = FanControlCoordinator.makeReadOnlyFixture(
            defaults: defaults, profile: profile, snapshot: snapshot)
        let telemetry = FanTelemetryState.resolve(snapshot: snapshot)
        var draft = FanControlDraft(telemetry: telemetry, observedMode: fanControl.observedMode,
            synchronizesFans: fanControl.synchronizesManualFans)
        let original = draft.configuration
        func usesSummary(observedMode: GeekFanControlMode? = .systemAutomatic,
            expanded: Bool = false, busy: Bool = false, submitted: Bool = false,
            otherPendingChanges: Bool = false) -> Bool {
            FanControlPaletteView.usesCompactAutomaticLayout(isExpanded: expanded,
                observedMode: observedMode, draft: draft,
                hasPendingChanges: draft.hasChanges || otherPendingChanges,
                isBusy: busy, hasSubmittedDraft: submitted)
        }
        XCTAssertTrue(usesSummary())
        XCTAssertFalse(usesSummary(observedMode: nil), "Unknown must never look like confirmed automatic")
        XCTAssertFalse(usesSummary(expanded: true))
        XCTAssertFalse(usesSummary(busy: true))
        XCTAssertFalse(usesSummary(submitted: true))
        XCTAssertFalse(usesSummary(otherPendingChanges: true))
        draft.selectMode(.manual)
        draft.setPercentage(75, fanID: nil)
        XCTAssertFalse(usesSummary(), "A mode or target draft must keep its controls visible")
        draft.cancel()
        XCTAssertEqual(draft.configuration, original)
        XCTAssertTrue(usesSummary())
        XCTAssertNil(fanControl.requestedMode)
        XCTAssertFalse(fanControl.isApplying)
        XCTAssertEqual(fanControl.latestFanReadings, snapshot.fanReadings)
        XCTAssertTrue(fanControl.isDataOnlyFixture)

        let store = ScanStore(cleanupPreferences: defaults, cleanReportLoader: { [] })
        store.menuBarMonitorState.update(snapshot)
        let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe())
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
        let compactHeight = coordinator.panel.frame.height
        coordinator.state.setFanControlsExpanded(true)
        let expanded = await eventually { updateMeasurement() && coordinator.panel.frame.height > compactHeight }
        XCTAssertTrue(expanded, "Expanded controls must remeasure to fit the larger gauges and temperature source")
        XCTAssertTrue(visible.insetBy(dx: 6, dy: 6).contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)
        coordinator.state.setFanControlsExpanded(false)
        let collapsed = await eventually { updateMeasurement() && abs(coordinator.panel.frame.height - compactHeight) < 0.5 }
        XCTAssertTrue(collapsed)
        XCTAssertEqual(coordinator.presentationCount, 1)
        XCTAssertFalse(coordinator.panel.isVisible, "Native measurement stays hidden and must not operate the app")
        XCTAssertEqual(fanControl.observedMode, .systemAutomatic)
        XCTAssertNil(fanControl.requestedMode)
        XCTAssertFalse(fanControl.isApplying)
    }
    #endif

    func testProductionRootMeasuresFanControlsAndEditorInsideHiddenNativePanel() async throws {
        let suite = "ControlPaletteTests.ProductionRoot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let store = ScanStore(cleanupPreferences: defaults, cleanReportLoader: { [] })
        let snapshot = SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil,
            fanReadings: [SystemFanReading(
                index: 0, actualRPM: 1_620, minimumRPM: 1_200,
                maximumRPM: 6_000, targetRPM: nil
            )],
            temperatureReadings: [SystemTemperatureReading(zone: .chip, celsius: 51)]
        )
        store.menuBarMonitorState.update(snapshot)
        fanControl.process(snapshot: snapshot)
        let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe())
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
        coordinator.state.setFanControlsExpanded(true)
        let expandedMeasured = await eventually {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            // Full controls add capability details to the same selected mode;
            // they no longer stack the manual and curve editors together.
            return coordinator.panel.frame.height > compactHeight + 0.5
                && coordinator.panel.frame.height == coordinator.state.measuredContentHeight
        }
        XCTAssertTrue(expandedMeasured,
            "Expanded native measurement must grow: compact=\(compactHeight), expanded=\(coordinator.panel.frame.height)")
        XCTAssertTrue(bounds.contains(coordinator.panel.frame))
        XCTAssertEqual(coordinator.panel.frame.maxX, parent.frame.minX - ControlPaletteMetrics.gap, accuracy: 0.001)

        coordinator.state.showFanCurveEditor()
        let editorMeasured = await eventually {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            coordinator.panel.displayIfNeeded()
            return coordinator.state.measuredContentHeight != nil
                && coordinator.panel.frame.width == ControlPaletteMetrics.fanCurveSize.width
                && coordinator.panel.frame.height == coordinator.state.measuredContentHeight
        }
        XCTAssertTrue(editorMeasured)
        XCTAssertTrue(bounds.contains(coordinator.panel.frame))
        coordinator.state.showFanControls()
        coordinator.state.setFanControlsExpanded(false)
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
        let suite = "ControlPaletteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let artifactDirectory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_LAYOUT_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let artifactDirectory {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        }
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        for language in [AppLanguage.zhHans, .english] {
            var arguments = previousArguments
            arguments[L10n.languageDefaultsKey] = language.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for dark in [false, true] {
                for state in states {
                    let suite = "ControlPaletteTests.Layout.\(UUID().uuidString)"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
                    let snapshot = fixtureSnapshot(profile)
                    let fanControl = FanControlCoordinator.makeReadOnlyFixture(
                        defaults: defaults, profile: profile, snapshot: snapshot)
                    let store = ScanStore(cleanupPreferences: defaults, cleanReportLoader: { [] })
                    store.menuBarMonitorState.update(snapshot)
                    let health = ComputerHealthStore(probe: ControlPaletteUnusedHealthProbe())
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
                    for expanded in [false, true] {
                        coordinator.state.setFanControlsExpanded(expanded)
                        let fits = await eventually {
                            host.layoutSubtreeIfNeeded()
                            coordinator.panel.displayIfNeeded()
                            guard let measured = coordinator.state.measuredContentHeight else { return false }
                            return abs(coordinator.panel.frame.height - measured) < 0.5
                        }
                        XCTAssertTrue(fits, "\(state) must fit its measured content, expanded=\(expanded)")
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
                            let name = "\(language.rawValue)-\(state.rawValue)-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "compact").png"
                            try png.write(to: artifactDirectory.appendingPathComponent(name))
                        }
                    }
                }
            }
        }
    }
    #endif

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
