import XCTest
@testable import StorageCleanerMac

#if DEBUG
final class MiniWindowDemoDataTests: XCTestCase {
    func testValidationOptionsCannotEnableDemoOrChangeDefaultDataWithoutDemoFlag() {
        let options = [
            "--debug-memory-used-percent=20",
            "--debug-memory-pressure=critical",
            "--debug-cpu-pattern=missing",
        ]
        XCTAssertNil(MiniWindowDemoData.validationOptions(arguments: options))
        let plain = MiniWindowDemoData.makeFixture(arguments: [])
        let withoutFlag = MiniWindowDemoData.makeFixture(arguments: options)
        XCTAssertEqual(withoutFlag.telemetry, plain.telemetry)
        XCTAssertEqual(
            MiniWindowDemoData.makeMemorySnapshot(arguments: options).measuredUsedBytes,
            MiniWindowDemoData.makeMemorySnapshot(arguments: []).measuredUsedBytes
        )
        let liveDate = MiniWindowDemoData.referenceDate.addingTimeInterval(12_345)
        XCTAssertEqual(MiniWindowDemoData.chartDate(liveDate: liveDate, arguments: options), liveDate)

        for invalid in [
            ["--debug-memory-used-percent=21"],
            ["--debug-memory-pressure=unknown"],
            ["--debug-cpu-pattern=unknown"],
            ["--debug-memory-used-percent=20", "--debug-memory-used-percent=90"],
        ] {
            XCTAssertNil(MiniWindowDemoData.validationOptions(
                arguments: [MiniWindowDemoData.launchArgument] + invalid
            ))
        }
    }

    func testMemoryValidationFixturesKeepOneTrackAndIndependentPressureGrades() throws {
        let physical: UInt64 = 48 * 1_024 * 1_024 * 1_024
        let grades: [(String, MemoryPressureLevel)] = [
            ("normal", .normal), ("elevated", .elevated), ("critical", .critical),
        ]
        for percent in [20, 55, 90] {
            var firstComposition: MemoryRingComposition?
            for (argument, grade) in grades {
                let arguments = [MiniWindowDemoData.launchArgument,
                    "--debug-memory-used-percent=\(percent)", "--debug-memory-pressure=\(argument)"]
                let snapshot = MiniWindowDemoData.makeMemorySnapshot(arguments: arguments)
                let composition = try XCTUnwrap(snapshot.ringComposition)
                XCTAssertEqual(snapshot.measurements.physicalBytes.value, physical)
                XCTAssertEqual(try XCTUnwrap(snapshot.measuredUsedRatio), Double(percent) / 100, accuracy: 0.000_000_001)
                XCTAssertEqual(snapshot.reportablePressureLevel, grade)
                XCTAssertNil(snapshot.pressureHeadroomPercent)
                XCTAssertNil(snapshot.pressureEstimatePercent)
                XCTAssertEqual(composition.appOrOtherBytes + composition.wiredBytes + composition.compressedBytes, composition.usedBytes)
                XCTAssertEqual(composition.availableBytes + composition.usedBytes, physical)
                XCTAssertLessThanOrEqual(snapshot.topProcesses.reduce(0) { $0 + $1.residentBytes }, Int64(composition.appOrOtherBytes))
                if let firstComposition { XCTAssertEqual(composition, firstComposition) }
                firstComposition = composition

                let fixture = MiniWindowDemoData.makeFixture(arguments: arguments)
                XCTAssertTrue(fixture.telemetry.allSatisfy {
                    $0.memory == snapshot.measuredUsedRatio.map { $0 * 100 }
                        && $0.memoryPressure == nil
                })
                XCTAssertEqual(fixture.snapshot.metrics.first { $0.kind == .memoryUsage }?.value, snapshot.usedPercentText)
                XCTAssertEqual(fixture.telemetry.last?.date, snapshot.generatedAt)
            }
        }
    }

    func testCPUValidationFixturesHaveExactTimestampsAndObservableOneAndFiveMinuteWindows() throws {
        let reference = MiniWindowDemoData.referenceDate
        for pattern in MiniWindowDemoData.CPUValidationPattern.allCases {
            let fixture = MiniWindowDemoData.makeFixture(arguments: [
                MiniWindowDemoData.launchArgument, "--debug-cpu-pattern=\(pattern.rawValue)",
            ])
            XCTAssertEqual(fixture.telemetry.count, 301)
            XCTAssertEqual(fixture.telemetry.first?.date, reference.addingTimeInterval(-300))
            XCTAssertEqual(fixture.telemetry.last?.date, reference)
            for (previous, current) in zip(fixture.telemetry, fixture.telemetry.dropFirst()) {
                XCTAssertEqual(current.date.timeIntervalSince(previous.date), 1)
            }
            let minute = MenuBarHistoryRetention.selected(
                fixture.telemetry, duration: 60, date: \.date, referenceDate: reference
            )
            let fiveMinutes = MenuBarHistoryRetention.selected(
                fixture.telemetry, duration: 300, date: \.date, referenceDate: reference
            )
            XCTAssertEqual(minute.count, 61)
            XCTAssertEqual(fiveMinutes.count, 301)
            XCTAssertEqual(fixture.snapshot.cpuUsageBreakdown?.totalPercent, fixture.telemetry.last?.cpuTotal)
            for point in fixture.telemetry {
                if let total = point.cpuTotal {
                    XCTAssertEqual(try XCTUnwrap(point.cpuUser) + (try XCTUnwrap(point.cpuSystem)), total, accuracy: 0.000_001)
                } else {
                    XCTAssertNil(point.cpuUser)
                    XCTAssertNil(point.cpuSystem)
                }
            }
            switch pattern {
            case .low:
                XCTAssertTrue(fiveMinutes.allSatisfy { $0.cpuTotal == 6 })
            case .step:
                XCTAssertTrue(minute.allSatisfy { $0.cpuTotal == 70 })
                XCTAssertEqual(fiveMinutes.first?.cpuTotal, 10)
                XCTAssertEqual(fiveMinutes[210].cpuTotal, 70)
            case .spike:
                XCTAssertEqual(minute.filter { $0.cpuTotal == 90 }.count, 5)
                XCTAssertEqual(minute.last?.cpuTotal, 10)
            case .missing:
                let missing = minute.filter { $0.cpuTotal == nil }
                XCTAssertEqual(missing.count, 10)
                XCTAssertEqual(missing.first?.date, reference.addingTimeInterval(-30))
                XCTAssertEqual(missing.last?.date, reference.addingTimeInterval(-21))
                XCTAssertFalse(fiveMinutes.contains { $0.cpuTotal == 0 })
            }
        }
    }

    func testMemoryAndCPUValidationOverridesCanBeCombinedWithoutChangingFanFactory() throws {
        let arguments = [MiniWindowDemoData.launchArgument,
            "--debug-memory-used-percent=55", "--debug-memory-pressure=normal", "--debug-cpu-pattern=missing"]
        let fixture = MiniWindowDemoData.makeFixture(arguments: arguments)
        let baseline = MiniWindowDemoData.makeFixture(arguments: [])
        let memory = MiniWindowDemoData.makeMemorySnapshot(arguments: arguments)
        XCTAssertTrue(fixture.telemetry.allSatisfy { $0.memory == memory.measuredUsedRatio.map { $0 * 100 } })
        XCTAssertEqual(fixture.snapshot.fanReadings, baseline.snapshot.fanReadings)
        XCTAssertEqual(fixture.snapshot.fanAvailability, baseline.snapshot.fanAvailability)
        XCTAssertEqual(fixture.snapshot.temperatureReadings, baseline.snapshot.temperatureReadings)
        XCTAssertEqual(fixture.telemetry.last?.fanRPM, baseline.telemetry.last?.fanRPM)
        XCTAssertEqual(fixture.telemetry.last?.fanTargetRPM, baseline.telemetry.last?.fanTargetRPM)
    }

    func testMemoryFixturesProvideMeasuredCompositionAndDistinctResult() throws {
        let before = MiniWindowDemoData.memorySnapshot
        let after = MiniWindowDemoData.memoryAfterQuitSnapshot
        let composition = try XCTUnwrap(before.ringComposition)
        XCTAssertEqual(composition.usedRatio, 39.0 / 48, accuracy: 0.000_001)
        XCTAssertEqual(before.reportablePressureLevel, .elevated)
        XCTAssertGreaterThan(try XCTUnwrap(after.ringComposition).availableBytes,
                             composition.availableBytes)
        XCTAssertEqual(after.reportablePressureLevel, .normal)
    }

    func testMemoryFixtureHistoryEndsAtTheSameSnapshotAndFormula() throws {
        let snapshot = MiniWindowDemoData.memorySnapshot
        let last = try XCTUnwrap(MiniWindowDemoData.fixture.telemetry.last)
        XCTAssertEqual(last.date, snapshot.generatedAt)
        XCTAssertEqual(try XCTUnwrap(last.memory), try XCTUnwrap(snapshot.measuredUsedRatio) * 100, accuracy: 0.000_001)
        XCTAssertEqual(last.memoryPressure, snapshot.pressureEstimatePercent.map(Double.init))
        XCTAssertEqual(last.compressedMemoryBytes, snapshot.measurements.compressedBytes.value)
        XCTAssertEqual(last.swapUsedBytes, snapshot.measurements.swapUsedBytes.value)
    }

    func testPanelSnapshotCaptureModeRequiresItsDedicatedArgumentPrefix() {
        XCTAssertTrue(MiniWindowDemoData.isCapturingMenuBarPanelSnapshots(arguments: [
            MiniWindowDemoData.launchArgument,
            "--capture-menu-bar-panel-directory=/tmp/panel-capture",
        ]))
        XCTAssertFalse(MiniWindowDemoData.isCapturingMenuBarPanelSnapshots(arguments: [
            MiniWindowDemoData.launchArgument,
            "--open-menu-bar-panel",
        ]))
        XCTAssertFalse(MiniWindowDemoData.isCapturingMenuBarPanelSnapshots(arguments: [
            "--capture-menu-bar-panel-directory",
        ]))

        XCTAssertTrue(MiniWindowDemoData.isCapturingPowerMenuBarPanelSnapshots(arguments: [
            MiniWindowDemoData.launchArgument,
            MiniWindowDemoData.menuBarPanelSnapshotPowerArgument,
        ]))
        XCTAssertFalse(MiniWindowDemoData.isCapturingPowerMenuBarPanelSnapshots(arguments: [
            MiniWindowDemoData.launchArgument,
            "--capture-menu-bar-panel-power=1",
        ]))

        XCTAssertEqual(
            MiniWindowDemoData.capturedMenuBarPanelSection(arguments: [
                "--capture-menu-bar-panel-section=network",
            ]),
            .network
        )
        XCTAssertNil(MiniWindowDemoData.capturedMenuBarPanelSection(arguments: [
            "--capture-menu-bar-panel-section=overview",
        ]))
        XCTAssertNil(MiniWindowDemoData.capturedMenuBarPanelSection(arguments: [
            "--capture-menu-bar-panel-section=unknown",
        ]))
    }

    func testPowerModeSnapshotUsesItsDedicatedOptInArgument() {
        XCTAssertFalse(MiniWindowDemoData.isCapturingPowerMenuBarPanelSnapshots(
            arguments: [MiniWindowDemoData.menuBarPanelSnapshotPowerModeArgument]
        ))
        XCTAssertTrue(MiniWindowDemoData.menuBarPanelSnapshotPowerModeArgument
            .hasPrefix("--capture-menu-bar-panel-power-mode"))
    }

    func testGoldenSnapshotScenariosUseExplicitPanelRoutes() {
        let capture = "--capture-menu-bar-panel-directory=/tmp/panel-capture"
        let arguments = [
            MiniWindowDemoData.launchArgument,
            capture,
            "--capture-menu-bar-panel-scenario=menu.memory.secondary",
        ]
        XCTAssertEqual(
            MiniWindowDemoData.capturedMenuBarPanelScenario(arguments: arguments),
            .memorySecondary
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.overviewBaseDark.route,
            .overview
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.memorySecondary.route,
            .secondary(.memory)
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.cpuHistory.route,
            .tertiary(.processor, .processor)
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.cpuUsageInspector.route,
            .inline(
                .processor,
                MiniWindowDemoData.MenuBarSnapshotScenario.cpuUsageInspector.debugRouteIdentifier
            )
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.sensorFanSpeedHistory.expectedPanelCount,
            3
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.memoryQuitConfirmation.route,
            .secondary(.memory)
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.networkVPNPPP.route,
            .inline(
                .network,
                MiniWindowDemoData.MenuBarSnapshotScenario.networkVPNPPP.debugRouteIdentifier
            )
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.networkVPNDisconnectConfirmation.expectedPanelCount,
            3
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.fanControlFull.route,
            .inline(
                .sensors,
                MiniWindowDemoData.MenuBarSnapshotScenario.fanControlFull.debugRouteIdentifier
            )
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.powerModeAndChargeTarget.route,
            .inline(
                .power,
                MiniWindowDemoData.MenuBarSnapshotScenario.powerModeAndChargeTarget.debugRouteIdentifier
            )
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.memorySecondary.expectedPanelCount,
            2
        )
        XCTAssertEqual(
            MiniWindowDemoData.MenuBarSnapshotScenario.cpuHistory.expectedPanelCount,
            3
        )
        XCTAssertFalse(MiniWindowDemoData.allowsTertiaryPresentation(arguments: arguments))
        XCTAssertTrue(MiniWindowDemoData.allowsTertiaryPresentation(arguments: [
            MiniWindowDemoData.launchArgument,
            capture,
            "--capture-menu-bar-panel-scenario=menu.cpu.history",
        ]))
        XCTAssertNil(MiniWindowDemoData.capturedMenuBarPanelScenario(arguments: [
            capture,
            "--capture-menu-bar-panel-scenario=menu.memory.secondary",
        ]))
        XCTAssertNil(MiniWindowDemoData.capturedMenuBarPanelScenario(arguments: [
            MiniWindowDemoData.launchArgument,
            capture,
            "--capture-menu-bar-panel-scenario=menu.unknown",
        ]))
    }

    func testFixtureChartClockKeepsRecentHistoryAndLiveClockUnchanged() {
        let liveDate = MiniWindowDemoData.referenceDate.addingTimeInterval(90 * 86_400)
        XCTAssertEqual(MiniWindowDemoData.chartDate(liveDate: liveDate, arguments: []), liveDate)
        let fixedDate = MiniWindowDemoData.chartDate(
            liveDate: liveDate, arguments: [MiniWindowDemoData.launchArgument]
        )
        var history = MenuBarTelemetryHistory()
        history.restore(MiniWindowDemoData.fixture.telemetry)
        let points = history.points(within: 120, referenceDate: fixedDate)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.last?.date, MiniWindowDemoData.referenceDate)
        XCTAssertTrue(history.points(within: 120, referenceDate: liveDate).isEmpty)
    }

    func testFixtureUsesFixedCurrentValuesAndOneHourHistory() {
        let fixture = MiniWindowDemoData.fixture

        XCTAssertEqual(fixture.snapshot.generatedAt, MiniWindowDemoData.referenceDate)
        XCTAssertEqual(fixture.snapshot.cpuUsageBreakdown?.totalPercent, 34)
        XCTAssertEqual(fixture.snapshot.networkThroughput?.downBytesPerSecond, 3_800_000)
        XCTAssertEqual(fixture.snapshot.networkThroughput?.upBytesPerSecond, 420_000)
        XCTAssertEqual(fixture.telemetry.count, 121)
        XCTAssertEqual(
            fixture.telemetry.first?.date,
            MiniWindowDemoData.referenceDate.addingTimeInterval(-3_600)
        )
        XCTAssertEqual(fixture.telemetry.last?.date, MiniWindowDemoData.referenceDate)
        XCTAssertEqual(fixture.telemetry.last?.cpuTotal, 34)
        XCTAssertEqual(fixture.telemetry.last?.cpuUser, 22)
        XCTAssertEqual(fixture.telemetry.last?.cpuSystem, 12)
        XCTAssertEqual(fixture.telemetry.last?.downBytesPerSecond, 3_800_000)
        XCTAssertEqual(fixture.telemetry.last?.upBytesPerSecond, 420_000)
        XCTAssertEqual(
            MenuBarHistoryRetention.selected(
                fixture.telemetry,
                duration: GeekChartRange.oneHour.duration,
                date: \.date,
                referenceDate: MiniWindowDemoData.referenceDate
            ).map(\.date),
            fixture.telemetry.map(\.date)
        )
        XCTAssertEqual(MiniWindowDemoData.processorTelemetry.clusters.first?.frequencyMHz, 3_600)
        XCTAssertEqual(MiniWindowDemoData.energyApps.map(\.name), [
            "Storage Cleaner",
            "Preview",
            "Safari",
        ])
        XCTAssertEqual(MiniWindowDemoData.memorySnapshot.pressureFreePercentage, 51)
        XCTAssertEqual(MiniWindowDemoData.storageSnapshot.availableBytes, 480_000_000_000)
        XCTAssertEqual(MiniWindowDemoData.nativeDiskIOHistory.count, 121)
        XCTAssertEqual(MiniWindowDemoData.nativeDiskIOHistory.last?.readBytesPerSecond, 4_200_000)
        XCTAssertEqual(MiniWindowDemoData.nativeDiskIOHistory.last?.writeBytesPerSecond, 1_100_000)
        XCTAssertEqual(MiniWindowDemoData.networkInterfaceSnapshot.interfaceName, "en0")
        XCTAssertEqual(MiniWindowDemoData.networkInterfaceSnapshot.ssid, "Studio Wi-Fi")
        XCTAssertEqual(MiniWindowDemoData.publicNetworkAddressSnapshot.ipv4Address, "203.0.113.35")
        XCTAssertEqual(
            MiniWindowDemoData.memorySnapshot.appsByResidentUsage.map(\.name),
            ["ChatGPT", "Google Chrome", "node", "WorkBuddy AI", "moomoo"]
        )
        XCTAssertEqual(MiniWindowDemoData.memorySnapshot.usedPercentText, "81%")
        XCTAssertEqual(MiniWindowDemoData.memorySnapshot.selectableQuitProcesses.map(\.id), [201, 202, 204, 205])
        XCTAssertEqual(
            MiniWindowDemoData.memoryQuitResult.executionResult?.targetResults.count,
            4
        )
        XCTAssertEqual(MiniWindowDemoData.batterySnapshot.chargePercent, 76)
        XCTAssertEqual(MiniWindowDemoData.powerHistory.last?.chargePercent, 76)
        XCTAssertEqual(MiniWindowDemoData.healthSummary.batteryPowerMode, .automatic)
        XCTAssertEqual(MiniWindowDemoData.fanTelemetry(for: .dualFan).fanCount, 2)

        guard let pppTunnel = MiniWindowDemoData.vpnTunnel(for: .networkVPNPPP),
              let readOnlyTunnel = MiniWindowDemoData.vpnTunnel(for: .networkVPNReadOnly) else {
            return XCTFail("Expected deterministic VPN fixtures")
        }
        XCTAssertEqual(pppTunnel.protocolKind, .ppp)
        XCTAssertTrue(MiniWindowDemoData.vpnCapabilityResolver.preflight(for: pppTunnel).canExecute)
        XCTAssertEqual(
            MiniWindowDemoData.vpnCapabilityResolver.preflight(for: readOnlyTunnel).failure,
            .readOnly
        )
    }

    func testBatteryFixturesKeepLowFrequencyLevelsAndTruthfulPowerFacts() {
        let charging = MiniWindowDemoData.powerHistory(for: .charging)
        XCTAssertEqual(MiniWindowDemoData.batterySnapshot(for: .charging).timeToFullChargeMinutes, 78)
        XCTAssertTrue(charging.allSatisfy {
            $0.powerSource == .acPower && $0.isCharging == true
        })
        assertSlowSteps(charging.compactMap(\.chargePercent), increasing: true)
        assertHasStatePlateaus(charging.compactMap(\.chargePercent))

        let battery = MiniWindowDemoData.powerHistory(for: .battery)
        XCTAssertEqual(MiniWindowDemoData.batterySnapshot(for: .battery).timeToEmptyMinutes, 266)
        XCTAssertTrue(battery.allSatisfy {
            $0.powerSource == .batteryPower && $0.isCharging == false
        })
        assertSlowSteps(battery.compactMap(\.chargePercent), increasing: false)
        assertHasStatePlateaus(battery.compactMap(\.chargePercent))

        let charged = MiniWindowDemoData.powerHistory(for: .charged)
        XCTAssertTrue(charged.allSatisfy {
            $0.chargePercent == 100
                && $0.powerSource == .acPower
                && $0.isCharging == false
        })
        XCTAssertEqual(MiniWindowDemoData.batterySnapshot(for: .charged).isFullyCharged, true)

        assertTransition(
            MiniWindowDemoData.powerHistory(for: .batteryToExternal),
            from: .batteryPower,
            to: .acPower
        )
        assertTransition(
            MiniWindowDemoData.powerHistory(for: .externalToBattery),
            from: .acPower,
            to: .batteryPower
        )

        let missing = MiniWindowDemoData.powerHistory(for: .missing)
        XCTAssertTrue(missing.allSatisfy {
            $0.chargePercent == nil && $0.powerSource == .unknown
        })
        XCTAssertFalse(missing.contains { $0.chargePercent == 0 })
    }

    private func assertSlowSteps(_ levels: [Double], increasing: Bool) {
        XCTAssertFalse(levels.isEmpty)
        for (previous, next) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(next - previous), 1)
            if increasing {
                XCTAssertGreaterThanOrEqual(next, previous)
            } else {
                XCTAssertLessThanOrEqual(next, previous)
            }
        }
    }

    private func assertHasStatePlateaus(_ levels: [Double]) {
        let repeatedPairs = zip(levels, levels.dropFirst()).filter(==).count
        XCTAssertGreaterThan(repeatedPairs, levels.count / 2)
    }

    private func assertTransition(
        _ history: [MenuBarPowerHistoryPoint],
        from: BatteryPowerSource,
        to: BatteryPowerSource
    ) {
        let sources = history.compactMap(\.powerSource)
        let transitionIndex = try? XCTUnwrap(
            sources.firstIndex(where: { $0 == to })
        )
        XCTAssertEqual(sources.first, from)
        XCTAssertEqual(transitionIndex, 61)
        XCTAssertTrue(sources.prefix(61).allSatisfy { $0 == from })
        XCTAssertTrue(sources.dropFirst(61).allSatisfy { $0 == to })
    }
}
#endif
