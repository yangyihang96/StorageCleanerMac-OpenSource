import Combine
import ServiceManagement
import XCTest
import FanControlShared
@testable import StorageCleanerMac

final class FanControlPlannerTests: XCTestCase {
    @MainActor
    func testUnchangedHelperStatusDoesNotInvalidatePanelObservers() {
        let suiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .notRegistered,
            requestSender: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .notRegistered }
        )
        var publicationCount = 0
        let cancellable = coordinator.objectWillChange.sink {
            publicationCount += 1
        }

        coordinator.refreshStatus()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testFanSetOnlyBoostsAboveCurrentSystemSpeed() {
        let readings = [
            fan(index: 0, actual: 2_500),
            fan(index: 1, actual: 6_000),
        ]

        let plan = FanControlPlanner.plan(
            mode: .fanSet,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: readings,
            temperatureReadings: nil
        )

        XCTAssertEqual(plan?.targetRPMByFan, [0: 5_600])
        XCTAssertEqual(plan?.automaticFanIDs, [1])
        XCTAssertEqual(plan?.restoresAllFans, false)
    }

    func testTemperatureCurveUsesHottestRealSensor() {
        let plan = FanControlPlanner.plan(
            mode: .customCurve,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 50,
            curveHighTemperature: 90,
            thermalState: .fair,
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .battery, celsius: 39),
                SystemTemperatureReading(zone: .chip, celsius: 90),
            ]
        )

        XCTAssertEqual(plan?.targetRPMByFan, [0: 7_800])
        XCTAssertEqual(plan?.automaticFanIDs, [])
    }

    func testCustomCurveRejectsFiniteOutOfHardwareRangeTemperatures() {
        for temperature in [-200.0, 500.0] {
            XCTAssertNil(FanControlPlanner.plan(
                mode: .customCurve,
                fanSet: .balanced,
                manualFraction: 0.7,
                curveLowTemperature: 50,
                curveHighTemperature: 90,
                thermalState: .nominal,
                fanReadings: [fan(index: 0, actual: 2_500)],
                temperatureReadings: [
                    SystemTemperatureReading(
                        zone: .chip,
                        celsius: temperature
                    ),
                ]
            ), "Expected \(temperature)°C to fail closed")
        }
    }

    @MainActor
    func testOutOfRangeCurveTemperatureRequestsAutomaticRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: FanControlTestClock(Date(timeIntervalSince1970: 100)),
            recorder: recorder
        )
        coordinator.selectedMode = .customCurve
        let snapshot = SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 500),
            ]
        )

        coordinator.process(snapshot: snapshot)
        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }

        XCTAssertNil(snapshot.temperatureReadings)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertFalse(recorder.requests.contains { $0.operation == .apply })
        XCTAssertTrue(recorder.requests.contains {
            $0.operation == .restoreAutomatic
        })
    }

    @MainActor
    func testInvalidSecondaryCurveSensorRequestsAutomaticRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: FanControlTestClock(Date(timeIntervalSince1970: 110)),
            recorder: recorder
        )
        coordinator.selectedMode = .customCurve

        coordinator.process(snapshot: SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 110),
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .battery, celsius: -200),
                SystemTemperatureReading(zone: .chip, celsius: 60),
            ]
        ))

        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertFalse(recorder.requests.contains { $0.operation == .apply })
        XCTAssertTrue(recorder.requests.contains { $0.operation == .restoreAutomatic })
    }

    func testCustomCurveInterpolatesPerFanProfiles() {
        let shared = [
            FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.20),
            FanCurvePoint(temperatureCelsius: 80, speedFraction: 0.80),
        ]
        let faster = [
            FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.50),
            FanCurvePoint(temperatureCelsius: 80, speedFraction: 1.00),
        ]
        let configuration = FanCurveConfiguration(
            synchronizesFans: false,
            sharedPoints: shared,
            pointsByFan: [1: faster]
        ).normalized()

        let plan = FanControlPlanner.plan(
            mode: .customCurve,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [fan(index: 0, actual: 2_300), fan(index: 1, actual: 2_300)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 60),
            ],
            curveConfiguration: configuration
        )

        XCTAssertEqual(plan?.targetRPMByFan, [0: 5_050, 1: 6_425])
    }

    func testCurveNormalizationRejectsInvalidAndDescendingValues() {
        let points = FanCurveConfiguration.normalizedPoints([
            FanCurvePoint(temperatureCelsius: .nan, speedFraction: 0.5),
            FanCurvePoint(temperatureCelsius: 120, speedFraction: 0.2),
            FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.8),
            FanCurvePoint(temperatureCelsius: 60, speedFraction: 0.3),
        ])

        XCTAssertEqual(points.map(\.temperatureCelsius), [40, 60, 105])
        XCTAssertEqual(points.map(\.speedFraction), [0.8, 0.8, 0.8])
        XCTAssertTrue(points.allSatisfy {
            FanCurveConfiguration.temperatureRange.contains($0.temperatureCelsius)
                && (0...1).contains($0.speedFraction)
        })
    }

    func testCurveConfigurationRoundTripsWithoutLosingFanProfiles() throws {
        let configuration = FanCurveConfiguration(
            synchronizesFans: false,
            sharedPoints: FanCurveConfiguration.defaultPoints,
            pointsByFan: [1: [
                FanCurvePoint(temperatureCelsius: 45, speedFraction: 0.5),
                FanCurvePoint(temperatureCelsius: 85, speedFraction: 1),
            ]]
        ).normalized()

        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(FanCurveConfiguration.self, from: data),
            configuration
        )
    }

    func testSynchronizedCurveIgnoresPerFanOverride() {
        let shared = [
            FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.20),
            FanCurvePoint(temperatureCelsius: 80, speedFraction: 0.80),
        ]
        let configuration = FanCurveConfiguration(
            synchronizesFans: true,
            sharedPoints: shared,
            pointsByFan: [1: [
                FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.8),
                FanCurvePoint(temperatureCelsius: 80, speedFraction: 1),
            ]]
        ).normalized()

        XCTAssertEqual(
            configuration.points(forFanID: 0).map(\.speedFraction),
            configuration.points(forFanID: 1).map(\.speedFraction)
        )
    }

    func testMissingRangeRefusesCustomControl() {
        let reading = SystemFanReading(
            index: 0,
            actualRPM: 2_500,
            minimumRPM: nil,
            maximumRPM: 7_800,
            targetRPM: 2_500
        )

        XCTAssertNil(FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [reading],
            temperatureReadings: nil
        ))
    }

    func testDuplicateOrInvalidFanIdentityRefusesControlPlan() {
        let duplicate = [
            fan(index: 0, actual: 2_500),
            fan(index: 0, actual: 2_600),
        ]
        XCTAssertNil(FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: duplicate,
            temperatureReadings: nil
        ))

        XCTAssertNil(FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0.7,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [fan(index: -1, actual: 2_500)],
            temperatureReadings: nil
        ))
    }

    func testSeriousThermalStateRestoresAppleControl() {
        let plan = FanControlPlanner.plan(
            mode: .manual,
            fanSet: .maximum,
            manualFraction: 1,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .serious,
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: nil
        )

        XCTAssertEqual(plan, .restoreAll)
    }

    func testMaximumModeUsesEachHardwareReportedMaximum() {
        let plan = FanControlPlanner.plan(
            mode: .maximum,
            fanSet: .balanced,
            manualFraction: 0.4,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [
                fan(index: 0, actual: 7_750),
                SystemFanReading(
                    index: 1,
                    actualRPM: 6_195,
                    minimumRPM: 1_900,
                    maximumRPM: 6_200,
                    targetRPM: 6_195
                ),
            ],
            temperatureReadings: nil
        )

        XCTAssertEqual(plan?.targetRPMByFan, [0: 7_800, 1: 6_200])
        XCTAssertEqual(plan?.automaticFanIDs, [])
    }

    func testManualModeMapsHardwareMinimumAndMaximumFractions() {
        let reading = SystemFanReading(
            index: 0,
            actualRPM: 3_000,
            minimumRPM: 1_900,
            maximumRPM: 6_200,
            targetRPM: 3_000
        )

        let minimum = FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [reading],
            temperatureReadings: nil
        )
        let maximum = FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 1,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [reading],
            temperatureReadings: nil
        )

        XCTAssertEqual(minimum?.targetRPMByFan, [0: 1_900])
        XCTAssertEqual(minimum?.automaticFanIDs, [])
        XCTAssertEqual(maximum?.targetRPMByFan, [0: 6_200])
        XCTAssertEqual(maximum?.automaticFanIDs, [])
    }

    func testManualModeKeepsNearCurrentTargetExplicit() {
        let plan = FanControlPlanner.plan(
            mode: .manual,
            fanSet: .balanced,
            manualFraction: 0.5,
            curveLowTemperature: 48,
            curveHighTemperature: 86,
            thermalState: .nominal,
            fanReadings: [SystemFanReading(
                index: 0,
                actualRPM: 3_975,
                minimumRPM: 2_000,
                maximumRPM: 6_000,
                targetRPM: 3_975
            )],
            temperatureReadings: nil
        )

        XCTAssertEqual(plan?.targetRPMByFan, [0: 4_000])
        XCTAssertEqual(plan?.automaticFanIDs, [])
    }

    func testManualEntryStartsNearTheCurrentSynchronizedFanPosition() throws {
        let fraction = try XCTUnwrap(FanControlPlanner.manualEntryFraction(
            fanReadings: [
                SystemFanReading(
                    index: 0,
                    actualRPM: 3_400,
                    minimumRPM: 2_300,
                    maximumRPM: 7_800,
                    targetRPM: 3_400
                ),
                SystemFanReading(
                    index: 1,
                    actualRPM: 4_050,
                    minimumRPM: 1_900,
                    maximumRPM: 6_200,
                    targetRPM: 4_050
                ),
            ]
        ))

        XCTAssertEqual(fraction, 0.35, accuracy: 0.000_1)
        XCTAssertNil(FanControlPlanner.manualEntryFraction(fanReadings: [
            SystemFanReading(
                index: 0,
                actualRPM: 3_400,
                minimumRPM: nil,
                maximumRPM: 7_800,
                targetRPM: 3_400
            ),
        ]))
    }

    func testFanTargetProgressUsesActualRPMAndABoundedTolerance() {
        XCTAssertEqual(
            FanTargetProgressState.resolve(actualRPM: 3_000, targetRPM: 4_000),
            .increasing
        )
        XCTAssertEqual(
            FanTargetProgressState.resolve(actualRPM: 5_000, targetRPM: 4_000),
            .decreasing
        )
        XCTAssertEqual(
            FanTargetProgressState.resolve(actualRPM: 4_150, targetRPM: 4_000),
            .reached
        )
    }

    func testCapabilityProbeHidesWritesWithoutTrustedCompleteRanges() {
        let readable = HardwareFanCapabilityProbe.probe(
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 55),
            ],
            hasTrustedHelper: false,
            observedMode: .manual
        )
        XCTAssertTrue(readable.supportsReading)
        XCTAssertFalse(readable.supportsWriting)
        XCTAssertNil(readable.observedMode)
        XCTAssertTrue(readable.requiresPrivilegedHelper)
        XCTAssertEqual(readable.temperatureSensors, [.chip])
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: readable),
            [.systemAutomatic]
        )

        let incompleteRange = HardwareFanCapabilityProbe.probe(
            fanReadings: [SystemFanReading(
                index: 0,
                actualRPM: 2_500,
                minimumRPM: 2_300,
                maximumRPM: nil,
                targetRPM: 2_500
            )],
            temperatureReadings: [],
            hasTrustedHelper: true,
            observedMode: .manual
        )
        XCTAssertTrue(incompleteRange.supportsReading)
        XCTAssertFalse(incompleteRange.hasWritableRanges)
        XCTAssertFalse(incompleteRange.supportsWriting)
        XCTAssertNil(incompleteRange.observedMode)
        XCTAssertFalse(incompleteRange.requiresPrivilegedHelper)
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: incompleteRange),
            [.systemAutomatic]
        )

        let writable = HardwareFanCapabilityProbe.probe(
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 55),
            ],
            hasTrustedHelper: true,
            observedMode: .manual
        )
        XCTAssertTrue(writable.hasWritableRanges)
        XCTAssertTrue(writable.supportsWriting)
        XCTAssertEqual(writable.observedMode, .manual)
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: writable),
            [.systemAutomatic, .customCurve, .manual, .maximum]
        )

        let noTemperature = HardwareFanCapabilityProbe.probe(
            fanReadings: [fan(index: 0, actual: 2_500)],
            temperatureReadings: [],
            hasTrustedHelper: true,
            observedMode: .manual
        )
        XCTAssertTrue(noTemperature.supportsWriting)
        XCTAssertFalse(noTemperature.supportsCustomCurve)
        XCTAssertEqual(noTemperature.observedMode, .manual)
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: noTemperature),
            [.systemAutomatic, .manual, .maximum]
        )

        for invalidReadings in [
            [fan(index: -1, actual: 2_500)],
            [fan(index: 0, actual: 2_500), fan(index: 0, actual: 2_600)],
            [fan(index: 0, actual: -1)],
        ] {
            let invalidIdentity = HardwareFanCapabilityProbe.probe(
                fanReadings: invalidReadings,
                temperatureReadings: [],
                hasTrustedHelper: true,
                observedMode: .manual
            )
            XCTAssertTrue(invalidIdentity.supportsReading)
            XCTAssertFalse(invalidIdentity.hasWritableRanges)
            XCTAssertFalse(invalidIdentity.supportsWriting)
            XCTAssertNil(invalidIdentity.observedMode)
        }
    }

    func testSafetyPolicyRampsTargets() {
        let readings = [fan(index: 0, actual: 2_500)]
        let ramped = FanControlSafetyPolicy.rateLimited(
            FanControlPlan(
                targetRPMByFan: [0: 7_800],
                automaticFanIDs: [],
                restoresAllFans: false
            ),
            fanReadings: readings,
            previousTargets: [:],
            elapsed: FanControlSafetyPolicy.minimumUpdateInterval
        )

        XCTAssertEqual(ramped.targetRPMByFan, [0: 3_500])
    }

    func testAppliedTargetsRequireExactFanSetAndHardwareBounds() {
        let readings = [fan(index: 0, actual: 2_500)]
        XCTAssertTrue(
            FanControlSafetyPolicy.validatedAppliedTargets(
                expected: [0: 3_500],
                applied: [0: 3_500],
                fanReadings: readings
            )
        )
        XCTAssertFalse(
            FanControlSafetyPolicy.validatedAppliedTargets(
                expected: [0: 3_500],
                applied: [:],
                fanReadings: readings
            )
        )
        XCTAssertFalse(
            FanControlSafetyPolicy.validatedAppliedTargets(
                expected: [0: 3_500],
                applied: [0: 3_500, 1: 4_000],
                fanReadings: readings
            )
        )
        XCTAssertFalse(
            FanControlSafetyPolicy.validatedAppliedTargets(
                expected: [0: 3_500],
                applied: [0: 7_900],
                fanReadings: readings
            )
        )
        XCTAssertFalse(
            FanControlSafetyPolicy.validatedAppliedTargets(
                expected: [0: 3_500],
                applied: [0: 3_600],
                fanReadings: readings
            )
        )
    }

    @MainActor
    func testManualSelectionUsesCurrentRPMAndDebouncesSliderWrites() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 850))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        let currentRPM = 4_000
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: currentRPM))

        await coordinator.selectMode(.manual)
        try? await Task.sleep(for: .milliseconds(220))
        await waitUntilIdle(coordinator)

        XCTAssertEqual(
            coordinator.manualFraction,
            Double(currentRPM - 2_300) / Double(7_800 - 2_300),
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            recorder.requests.last(where: { $0.operation == .apply })?.targetRPMByFan,
            [0: currentRPM]
        )
        let initialApplyCount = recorder.requests.filter { $0.operation == .apply }.count

        coordinator.updateManualPercentage(20)
        coordinator.updateManualPercentage(45)
        coordinator.updateManualPercentage(80)
        try? await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(
            recorder.requests.filter { $0.operation == .apply }.count,
            initialApplyCount
        )

        try? await Task.sleep(for: .milliseconds(140))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(
            recorder.requests.filter { $0.operation == .apply }.count,
            initialApplyCount + 1
        )
        XCTAssertEqual(coordinator.manualFraction, 0.8, accuracy: 0.000_1)
    }

    @MainActor
    func testRapidModeSelectionIsSerialAndLatestAutomaticWins() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let sender = ControlledFanModeSender()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                try await sender.reply(to: request)
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )
        coordinator.process(snapshot: snapshot(
            at: Date(timeIntervalSince1970: 860),
            actualRPM: 4_000
        ))

        let first = Task { @MainActor in
            await coordinator.selectMode(.manual)
        }
        await sender.waitForPendingPing()
        let latest = Task { @MainActor in
            await coordinator.selectMode(.systemAutomatic)
        }
        await Task.yield()
        sender.resumePing(
            with: FanControlHelperReply(
                operation: .ping,
                success: false,
                message: "stale ping failure",
                appliedTargetRPMByFan: [:]
            )
        )
        await first.value
        await latest.value

        XCTAssertEqual(sender.maximumActiveRequestCount, 1)
        XCTAssertEqual(sender.requests.map(\.operation), [.ping, .restoreAutomatic])
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode, "A successful restore command contains no automatic-mode readback")
        XCTAssertFalse(coordinator.isSwitchingMode)
        XCTAssertFalse(coordinator.lastMessage?.contains("stale ping failure") == true)
    }

    @MainActor
    func testCriticalThermalSnapshotBlocksManualControlBeforeAnyWrite() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 875))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.process(snapshot: SystemMonitorSnapshot(
            generatedAt: clock.now,
            metrics: [],
            networkThroughput: nil,
            thermalState: .critical,
            fanReadings: [fan(index: 0, actual: 4_000)]
        ))

        await coordinator.selectMode(.manual)

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertFalse(recorder.requests.contains { $0.operation == .apply })
        XCTAssertTrue(
            coordinator.lastMessage?.contains("温度较高") == true
                || coordinator.lastMessage?.contains("thermal state is high") == true
        )
    }

    @MainActor
    func testSelectedModeRequiresMatchingHelperReadbackBeforeItIsObserved() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 900))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )

        coordinator.selectedMode = .manual

        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertNil(coordinator.observedMode)

        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.observedMode, .manual)
        let requestCount = recorder.requests.count
        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.watchdogSeconds + 1
        )
        coordinator.expireObservedModeIfNeeded()

        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(recorder.requests.count, requestCount)
    }

    @MainActor
    func testVerifiedObservationRenewsBeforeTheWatchdogLeaseExpires() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 925))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        coordinator.manualFraction = 0
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        let firstTarget = recorder.requests.last(where: {
            $0.operation == .apply
        })?.targetRPMByFan[0] ?? 2_300

        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.leaseRenewalInterval
        )
        coordinator.process(snapshot: snapshot(
            at: clock.now,
            actualRPM: firstTarget,
            targetRPM: firstTarget
        ))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)
        XCTAssertEqual(
            recorder.requests.last?.operation,
            .renewFanControlLease
        )
        let requestCount = recorder.requests.count

        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.watchdogSeconds - 1
        )
        coordinator.expireObservedModeIfNeeded()
        XCTAssertEqual(coordinator.observedMode, .manual)

        clock.now = clock.now.addingTimeInterval(2)
        coordinator.expireObservedModeIfNeeded()
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(recorder.requests.count, requestCount)
    }

    @MainActor
    func testFreshHelperReadbackOutranksLaggingTelemetryTarget() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 950))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)
        let verifiedTarget = recorder.requests.last(where: {
            $0.operation == .apply
        })?.targetRPMByFan[0] ?? 2_300

        clock.now = clock.now.addingTimeInterval(1)
        coordinator.process(snapshot: snapshot(
            at: clock.now,
            actualRPM: verifiedTarget,
            targetRPM: 0
        ))
        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertEqual(
            coordinator.observedMode,
            .manual,
            "A fresh authenticated Helper readback must not flicker off while passive telemetry catches up"
        )

        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.feedbackGracePeriod
        )
        coordinator.process(snapshot: snapshot(
            at: clock.now,
            actualRPM: verifiedTarget,
            targetRPM: 0
        ))
        XCTAssertNil(coordinator.observedMode)
    }

    @MainActor
    func testHardwareRangeChangeFailsClosedAndRequestsAutomaticRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 957))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual

        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)
        let applyCount = recorder.requests.filter { $0.operation == .apply }.count

        clock.now = clock.now.addingTimeInterval(2)
        coordinator.process(snapshot: SystemMonitorSnapshot(
            generatedAt: clock.now,
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanReadings: [SystemFanReading(
                index: 0,
                actualRPM: 3_300,
                minimumRPM: 2_300,
                maximumRPM: 7_600,
                targetRPM: 3_300
            )]
        ))

        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(
            recorder.requests.filter { $0.operation == .apply }.count,
            applyCount
        )
        XCTAssertTrue(recorder.requests.contains { $0.operation == .restoreAutomatic })
    }

    @MainActor
    func testRestoreKeepsAutomaticUnconfirmedAndCancelsTheVerifiedManualLease() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 965))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)

        await coordinator.selectMode(.systemAutomatic)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        let requestCount = recorder.requests.count
        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.feedbackGracePeriod + 1
        )
        coordinator.process(snapshot: snapshot(
            at: clock.now,
            actualRPM: 3_300,
            targetRPM: 0
        ))
        XCTAssertNil(
            coordinator.observedMode,
            "A zero target in monitoring telemetry is not automatic-mode readback"
        )
        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.watchdogSeconds + 1
        )
        coordinator.expireObservedModeIfNeeded()
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(recorder.requests.count, requestCount)
    }

    @MainActor
    func testUnreadableHardwareInvalidatesObservedMode() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 975))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)

        clock.now = clock.now.addingTimeInterval(1)
        coordinator.process(snapshot: SystemMonitorSnapshot(
            generatedAt: clock.now,
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanReadings: nil
        ))

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }
        XCTAssertTrue(recorder.requests.contains { $0.operation == .restoreAutomatic })
    }

    @MainActor
    func testDisconnectResetClearsObservationWithoutWritingHardware() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 990))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
        await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.observedMode, .manual)
        let requestCount = recorder.requests.count

        coordinator.disconnectForTermination()
        clock.now = clock.now.addingTimeInterval(
            FanControlSafetyPolicy.watchdogSeconds + 1
        )
        coordinator.expireObservedModeIfNeeded()

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(recorder.requests.count, requestCount)
    }

    @MainActor
    func testLaggingPhysicalRPMDoesNotCancelVerifiedTargetLease() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 1_000))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual

        for elapsed in stride(from: 0, through: 20, by: 2) {
            clock.now = Date(timeIntervalSince1970: 1_000 + Double(elapsed))
            coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: 2_300))
            await waitUntilIdle(coordinator)
        }

        let applyRequests = recorder.requests.filter { $0.operation == .apply }
        XCTAssertEqual(applyRequests.count, 4)
        XCTAssertEqual(applyRequests.first?.targetRPMByFan, [0: 3_300])
        XCTAssertTrue(applyRequests.allSatisfy(\.allowsRPMDecrease))
        XCTAssertGreaterThanOrEqual(
            recorder.requests.filter { $0.operation == .renewFanControlLease }.count,
            2
        )
        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertEqual(coordinator.observedMode, .manual)
        XCTAssertFalse(recorder.requests.contains { $0.operation == .restoreAutomatic })
    }

    @MainActor
    func testReachedFeedbackKeepsControlActiveAndAllowsTheNextWrite() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let clock = FanControlTestClock(Date(timeIntervalSince1970: 2_000))
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: clock,
            recorder: recorder
        )
        coordinator.selectedMode = .manual
        var actualRPM = 2_300

        for elapsed in stride(from: 0, through: 12, by: 2) {
            clock.now = Date(timeIntervalSince1970: 2_000 + Double(elapsed))
            coordinator.process(snapshot: snapshot(at: clock.now, actualRPM: actualRPM))
            await waitUntilIdle(coordinator)
            actualRPM = recorder.requests.last(where: { $0.operation == .apply })?
                .targetRPMByFan[0] ?? actualRPM
        }

        let applyRequests = recorder.requests.filter { $0.operation == .apply }
        XCTAssertEqual(applyRequests.first?.targetRPMByFan, [0: 3_300])
        XCTAssertEqual(applyRequests.count, 4)
        XCTAssertEqual(
            recorder.requests.filter { $0.operation == .renewFanControlLease }.count,
            1
        )
        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertFalse(recorder.requests.contains {
            $0.operation == .restoreAutomatic
        })
    }

    @MainActor
    func testTerminationRetriesAutomaticRestoreAfterHelperRejectsTheFirstRequest() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let recorder = FanControlRequestRecorder()
        recorder.restoreFailuresRemaining = 1
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: FanControlTestClock(Date(timeIntervalSince1970: 3_000)),
            recorder: recorder
        )
        coordinator.selectedMode = .manual

        await coordinator.prepareForTermination()

        for _ in 0..<100 where recorder.requests.filter({ $0.operation == .restoreAutomatic }).count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertGreaterThanOrEqual(
            recorder.requests.filter { $0.operation == .restoreAutomatic }.count,
            2
        )
    }

    @MainActor
    func testUnexpectedHelperInvalidationFailsClosedAndRequestsAutomaticRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let recorder = FanControlRequestRecorder()
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: FanControlTestClock(Date(timeIntervalSince1970: 3_500)),
            recorder: recorder
        )
        coordinator.selectedMode = .manual

        coordinator.handleUnexpectedHelperInvalidation()

        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertTrue(recorder.requests.contains {
            $0.operation == .restoreAutomatic
        })
        XCTAssertTrue(
            coordinator.lastMessage?.contains("意外退出") == true
                || coordinator.lastMessage?.contains("exited unexpectedly") == true
        )
    }

    @MainActor
    func testMismatchedApplyReplyFailsClosedAndRequestsAutomaticRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let recorder = FanControlRequestRecorder()
        recorder.applyReplyTargets = [:]
        let coordinator = makeCoordinator(
            defaults: defaults,
            clock: FanControlTestClock(Date(timeIntervalSince1970: 4_000)),
            recorder: recorder
        )
        coordinator.selectedMode = .manual

        coordinator.process(snapshot: snapshot(
            at: Date(timeIntervalSince1970: 4_000),
            actualRPM: 2_300
        ))
        await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertTrue(recorder.requests.contains { $0.operation == .apply })
        for _ in 0..<100 where !recorder.requests.contains(where: {
            $0.operation == .restoreAutomatic
        }) {
            await Task.yield()
        }
        XCTAssertTrue(recorder.requests.contains {
            $0.operation == .restoreAutomatic
        })
        XCTAssertTrue(
            coordinator.lastMessage?.contains("回报与请求不一致") == true
                || coordinator.lastMessage?.contains("did not match") == true
        )
    }

    @MainActor
    func testApplyTimeoutFailsClosedAndLateReplyCannotOverrideRestore() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let state = FanControlTimeoutTestState()
        defer { state.releasePendingApply() }
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                state.requests.append(request)
                if request.operation == .apply {
                    // Keep the success reply pending until automatic recovery
                    // has actually completed, independent of scheduler load.
                    await withCheckedContinuation { state.pendingApply = $0 }
                    state.didReturnDelayedApply = true
                }
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "late success",
                    appliedTargetRPMByFan: request.operation == .apply
                        ? request.targetRPMByFan
                        : [:]
                )
            },
            helperRequestTimeout: 0.01,
            fanWriteRequestTimeout: 0.01
        )
        coordinator.selectedMode = .manual

        coordinator.process(snapshot: snapshot(
            at: Date(timeIntervalSince1970: 4_500),
            actualRPM: 2_300
        ))
        await waitForCondition {
            coordinator.selectedMode == .systemAutomatic
                && !coordinator.isApplying
                && state.requests.contains { $0.operation == .restoreAutomatic }
        }

        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertFalse(coordinator.isApplying)
        XCTAssertTrue(state.requests.contains { $0.operation == .apply })
        XCTAssertTrue(state.requests.contains { $0.operation == .restoreAutomatic })
        XCTAssertTrue(
            coordinator.lastMessage?.contains("超时") == true
                || coordinator.lastMessage?.localizedCaseInsensitiveContains("timed out") == true
        )

        state.releasePendingApply()
        await waitForCondition { state.didReturnDelayedApply }
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        XCTAssertEqual(
            state.requests.filter { $0.operation == .apply }.count,
            1
        )
    }

    @MainActor
    func testSlowFanUnlockUsesFanWriteTimeoutInsteadOfGenericXPCTimeout() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let state = FanControlTimeoutTestState()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                state.requests.append(request)
                if request.operation == .apply {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "verified",
                    appliedTargetRPMByFan: request.operation == .apply
                        ? request.targetRPMByFan
                        : [:]
                )
            },
            helperRequestTimeout: 0.01,
            fanWriteRequestTimeout: 0.2
        )
        coordinator.selectedMode = .manual

        coordinator.process(snapshot: snapshot(
            at: Date(timeIntervalSince1970: 4_600),
            actualRPM: 2_300
        ))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coordinator.selectedMode, .manual)
        XCTAssertEqual(coordinator.observedMode, .manual)
        XCTAssertFalse(coordinator.isApplying)
        XCTAssertEqual(
            state.requests.filter { $0.operation == .apply }.count,
            1
        )
        XCTAssertFalse(state.requests.contains { $0.operation == .restoreAutomatic })
    }

    func testHelperApplyRequestHasBoundedWatchdog() {
        let request = FanControlHelperRequest.apply(FanControlPlan(
            targetRPMByFan: [0: 5_600],
            automaticFanIDs: [1],
            restoresAllFans: false
        ))

        XCTAssertEqual(request.operation, .apply)
        XCTAssertEqual(request.targetRPMByFan, [0: 5_600])
        XCTAssertEqual(request.automaticFanIDs, [1])
        XCTAssertFalse(request.allowsRPMDecrease)
        XCTAssertEqual(
            request.watchdogSeconds,
            FanControlSafetyPolicy.watchdogSeconds
        )

        let manualRequest = FanControlHelperRequest.apply(
            FanControlPlan(
                targetRPMByFan: [0: 3_200],
                automaticFanIDs: [],
                restoresAllFans: false
            ),
            allowsRPMDecrease: true
        )
        XCTAssertTrue(manualRequest.allowsRPMDecrease)

        XCTAssertEqual(
            FanControlHelperRequest.renewFanControlLease.operation,
            .renewFanControlLease
        )
        XCTAssertEqual(
            FanControlHelperRequest.renewFanControlLease.watchdogSeconds,
            FanControlSafetyPolicy.watchdogSeconds
        )
        XCTAssertEqual(FanControlSafetyPolicy.leaseRenewalInterval, 5)
        // 30s tolerates AppKit event-tracking pauses (menus, drags) that
        // freeze MainActor lease renewals, while keeping the dead-app
        // fail-safe: fans return to system control within half a minute.
        XCTAssertEqual(FanControlSafetyPolicy.watchdogSeconds, 30)
    }

    @MainActor
    func testLegacyMismatchResolvesToNeedsMigration() {
        XCTAssertEqual(
            FanControlCoordinator.resolvedStatus(
                serviceStatus: .notRegistered,
                legacyArtifactsPresent: true,
                legacyArtifactsCurrent: false
            ),
            .needsMigration
        )
        XCTAssertEqual(
            FanControlCoordinator.resolvedStatus(
                serviceStatus: .enabled,
                legacyArtifactsPresent: false,
                legacyArtifactsCurrent: false
            ),
            .enabled
        )
        XCTAssertEqual(
            FanControlCoordinator.resolvedStatus(
                serviceStatus: .notFound,
                legacyArtifactsPresent: false,
                legacyArtifactsCurrent: false
            ),
            .unavailable
        )
    }

    @MainActor
    func testLegacyMigrationFailureStaysClosedAndDoesNotRegister() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let state = LegacyMigrationTestState()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .needsMigration,
            legacyArtifactsPresentProvider: { state.artifactsPresent },
            legacyArtifactsCurrentProvider: { state.artifactsCurrent },
            legacyArtifactsSafeForRemovalProvider: { true },
            legacyUninstaller: {
                state.events.append("uninstall")
                throw LegacyMigrationTestError.denied
            },
            serviceStatusProvider: { state.serviceStatus },
            serviceRegistrar: {
                state.events.append("register")
                state.serviceStatus = .enabled
            }
        )
        coordinator.selectedMode = .manual

        await coordinator.migrateLegacyHelper()

        XCTAssertEqual(state.events, ["uninstall"])
        XCTAssertEqual(coordinator.helperStatus, .needsMigration)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertFalse(coordinator.hasTrustedHelper)
        XCTAssertNotNil(coordinator.lastMessage)
    }

    @MainActor
    func testSelectingModeWithMigrationRequirementKeepsMigrationMessage() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let state = LegacyMigrationTestState()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .needsMigration,
            legacyArtifactsPresentProvider: { state.artifactsPresent },
            legacyArtifactsCurrentProvider: { state.artifactsCurrent }
        )

        await coordinator.selectMode(.manual)

        XCTAssertEqual(coordinator.helperStatus, .needsMigration)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNotNil(coordinator.lastMessage)
        XCTAssertFalse(
            coordinator.lastMessage?.contains("Approve the system-control helper") == true
        )
    }

    @MainActor
    func testLegacyMigrationUninstallsReadsBackRegistersAndPings() async {
        let defaultsSuiteName = "FanControlPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let state = LegacyMigrationTestState()
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .needsMigration,
            requestSender: { request in
                XCTAssertEqual(request.operation, .ping)
                state.events.append("ping")
                return FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "ping ok",
                    appliedTargetRPMByFan: [:]
                )
            },
            legacyArtifactsPresentProvider: { state.artifactsPresent },
            legacyArtifactsCurrentProvider: { state.artifactsCurrent },
            legacyArtifactsSafeForRemovalProvider: { true },
            legacyUninstaller: {
                state.events.append("uninstall")
                state.artifactsPresent = false
            },
            serviceStatusProvider: { state.serviceStatus },
            serviceRegistrar: {
                state.events.append("register")
                state.serviceStatus = .enabled
            }
        )

        await coordinator.migrateLegacyHelper()

        XCTAssertEqual(state.events, ["uninstall", "register", "ping"])
        XCTAssertEqual(coordinator.helperStatus, .enabled)
        XCTAssertTrue(coordinator.isHelperReachable)
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
    }

    private func fan(index: Int, actual: Int) -> SystemFanReading {
        SystemFanReading(
            index: index,
            actualRPM: actual,
            minimumRPM: 2_300,
            maximumRPM: 7_800,
            targetRPM: actual
        )
    }

    @MainActor
    private func makeCoordinator(
        defaults: UserDefaults,
        clock: FanControlTestClock,
        recorder: FanControlRequestRecorder
    ) -> FanControlCoordinator {
        FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            now: { clock.now },
            requestSender: { request in recorder.reply(to: request) },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )
    }

    private func snapshot(
        at date: Date,
        actualRPM: Int,
        targetRPM: Int? = nil
    ) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(
            generatedAt: date,
            metrics: [],
            networkThroughput: nil,
            thermalState: .nominal,
            fanReadings: [SystemFanReading(
                index: 0,
                actualRPM: actualRPM,
                minimumRPM: 2_300,
                maximumRPM: 7_800,
                targetRPM: targetRPM ?? actualRPM
            )]
        )
    }

    @MainActor
    private func waitForCondition(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Expected asynchronous fan-control state did not arrive")
    }

    @MainActor
    private func waitUntilIdle(_ coordinator: FanControlCoordinator) async {
        for _ in 0..<100 {
            if !coordinator.isApplying { return }
            await Task.yield()
        }
        XCTFail("Fan control apply task did not finish")
    }
}

@MainActor
private final class LegacyMigrationTestState {
    var artifactsPresent = true
    var artifactsCurrent = false
    var serviceStatus: SMAppService.Status = .notRegistered
    var events: [String] = []
}

private enum LegacyMigrationTestError: Error {
    case denied
}

@MainActor
private final class FanControlTestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class FanControlRequestRecorder {
    private(set) var requests: [FanControlHelperRequest] = []
    var restoreFailuresRemaining = 0
    var applyReplyTargets: [Int: Int]?
    private var activeTargets: [Int: Int] = [:]

    func reply(to request: FanControlHelperRequest) -> FanControlHelperReply {
        requests.append(request)
        if request.operation == .restoreAutomatic, restoreFailuresRemaining > 0 {
            restoreFailuresRemaining -= 1
            return FanControlHelperReply(
                operation: request.operation,
                success: false,
                message: "restore rejected",
                appliedTargetRPMByFan: [:]
            )
        }
        if request.operation == .apply {
            activeTargets = applyReplyTargets ?? request.targetRPMByFan
        } else if request.operation == .restoreAutomatic {
            activeTargets = [:]
        }
        let replyTargets: [Int: Int]
        switch request.operation {
        case .apply, .renewFanControlLease:
            replyTargets = activeTargets
        case .ping, .readPowerConfiguration, .restoreAutomatic,
             .applyPowerMode, .validateFanCurve, .activateFanCurve,
             .updateFanCurve, .getFanCurveRuntimeState, .deactivateFanCurve:
            replyTargets = [:]
        }
        let curveRuntimeState: FanCurveRuntimeState? = switch request.operation {
        case .validateFanCurve, .getFanCurveRuntimeState, .deactivateFanCurve:
            .inactive
        case .activateFanCurve, .updateFanCurve:
            FanCurveRuntimeState(
                status: .active,
                activeProfileID: request.curveProfile?.id
            )
        case .renewFanControlLease where request.curveLeaseID != nil:
            FanCurveRuntimeState(status: .active)
        default:
            nil
        }
        return FanControlHelperReply(
            operation: request.operation,
            success: true,
            message: "ok",
            appliedTargetRPMByFan: replyTargets,
            curveRuntimeState: curveRuntimeState
        )
    }
}

@MainActor
private final class ControlledFanModeSender {
    private(set) var requests = [FanControlHelperRequest]()
    private(set) var maximumActiveRequestCount = 0
    private var activeRequestCount = 0
    private var pingContinuation:
        CheckedContinuation<FanControlHelperReply, any Error>?

    func reply(
        to request: FanControlHelperRequest
    ) async throws -> FanControlHelperReply {
        requests.append(request)
        activeRequestCount += 1
        maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }

        if request.operation == .ping {
            return try await withCheckedThrowingContinuation { continuation in
                pingContinuation = continuation
            }
        }
        return FanControlHelperReply(
            operation: request.operation,
            success: true,
            message: "ok",
            appliedTargetRPMByFan: [:]
        )
    }

    func waitForPendingPing() async {
        while pingContinuation == nil {
            await Task.yield()
        }
    }

    func resumePing(with reply: FanControlHelperReply) {
        pingContinuation?.resume(returning: reply)
        pingContinuation = nil
    }
}

@MainActor
private final class FanControlTimeoutTestState {
    var requests: [FanControlHelperRequest] = []
    var pendingApply: CheckedContinuation<Void, Never>?
    var didReturnDelayedApply = false

    func releasePendingApply() {
        let pending = pendingApply
        pendingApply = nil
        pending?.resume()
    }
}
