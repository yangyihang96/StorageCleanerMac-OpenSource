import Combine
import XCTest
@testable import StorageCleanerMac

final class SystemMonitorServiceTests: XCTestCase {
    func testProvidingPowerSourceTypeDistinguishesACBatteryUPSAndUnknown() {
        XCTAssertEqual(
            BatteryPowerService.powerSource(fromProvidingType: "AC Power"),
            .acPower
        )
        XCTAssertEqual(
            BatteryPowerService.powerSource(fromProvidingType: "Battery Power"),
            .batteryPower
        )
        XCTAssertEqual(
            BatteryPowerService.powerSource(fromProvidingType: "UPS Power"),
            .acPower
        )
        XCTAssertEqual(
            BatteryPowerService.powerSource(fromProvidingType: nil),
            .unknown
        )
    }

    func testSystemMonitorSnapshotDoesNotAssumeNormalThermalStateBeforeSampling() {
        let snapshot = SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            metrics: [],
            networkThroughput: nil
        )

        XCTAssertEqual(snapshot.thermalState, .unknown)
        XCTAssertEqual(snapshot.sensorAvailability, .unavailable)
    }

    func testCPUTickDeltaUsesActiveShareWithoutLaunchingPS() {
        let previous = SystemMonitorService.CPUUsageTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = SystemMonitorService.CPUUsageTicks(user: 130, system: 70, idle: 900, nice: 0)

        XCTAssertEqual(
            SystemMonitorService.cpuUsagePercent(current: current, previous: previous),
            50
        )
    }

    func testCPUTickDeltaDoesNotFabricateBreakdownWithoutPreviousSample() {
        let current = SystemMonitorService.CPUUsageTicks(
            user: 12_500,
            system: 3_000,
            idle: 84_000,
            nice: 500
        )

        XCTAssertNil(
            SystemMonitorService.cpuUsageBreakdown(
                current: current,
                previous: nil
            )
        )
        XCTAssertNil(
            SystemMonitorService.cpuUsagePercent(
                current: current,
                previous: nil
            )
        )
    }

    func testCPUTickDeltaExposesUserAndSystemBreakdown() throws {
        let previous = SystemMonitorService.CPUUsageTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = SystemMonitorService.CPUUsageTicks(user: 125, system: 70, idle: 900, nice: 5)

        let breakdown = try XCTUnwrap(
            SystemMonitorService.cpuUsageBreakdown(current: current, previous: previous)
        )

        XCTAssertEqual(breakdown.totalPercent, 50, accuracy: 0.001)
        XCTAssertEqual(breakdown.userPercent, 30, accuracy: 0.001)
        XCTAssertEqual(breakdown.systemPercent, 20, accuracy: 0.001)
    }

    func testCPUCoreTickDeltaKeepsOneRealValuePerCore() throws {
        let previous = [
            SystemMonitorService.CPUUsageTicks(user: 100, system: 50, idle: 850, nice: 0),
            SystemMonitorService.CPUUsageTicks(user: 20, system: 20, idle: 960, nice: 0),
        ]
        let current = [
            SystemMonitorService.CPUUsageTicks(user: 130, system: 70, idle: 900, nice: 0),
            SystemMonitorService.CPUUsageTicks(user: 25, system: 25, idle: 1_040, nice: 0),
        ]

        let usage = try XCTUnwrap(
            SystemMonitorService.cpuCoreUsagePercent(current: current, previous: previous)
        )

        XCTAssertEqual(usage.count, 2)
        XCTAssertEqual(usage[0], 50, accuracy: 0.001)
        XCTAssertEqual(usage[1], 11.111, accuracy: 0.001)
        XCTAssertNil(SystemMonitorService.cpuCoreUsagePercent(current: current, previous: nil))
        XCTAssertNil(SystemMonitorService.cpuCoreUsagePercent(current: [current[0]], previous: previous))
    }

    func testLoadAveragePreservesOneFiveAndFifteenMinuteSamples() throws {
        let load = try XCTUnwrap(
            SystemMonitorService.loadAverage(from: [2.5, 1.75, 0.5], sampleCount: 3)
        )

        XCTAssertEqual(load.oneMinute, 2.5)
        XCTAssertEqual(load.fiveMinutes, 1.75)
        XCTAssertEqual(load.fifteenMinutes, 0.5)
        XCTAssertNil(SystemMonitorService.loadAverage(from: [2.5, 1.75], sampleCount: 2))
    }

    func testBatteryPowerServiceParsesChargingACSnapshot() {
        let snapshot = BatteryPowerService.snapshot(fromPowerSourceDescription: [
            "Current Capacity": 44,
            "Max Capacity": 100,
            "Power Source State": "AC Power",
            "Is Charging": true,
            "Time to Empty": -1,
            "Time to Full Charge": 38
        ])

        XCTAssertEqual(snapshot.chargePercent, 44)
        XCTAssertEqual(snapshot.isCharging, true)
        XCTAssertEqual(snapshot.powerSource, .acPower)
        XCTAssertEqual(snapshot.isConnectedToAC, true)
        XCTAssertEqual(snapshot.isDischarging, false)
        XCTAssertNil(snapshot.timeToEmptyMinutes)
        XCTAssertEqual(snapshot.remainingTimeMinutes, 38)
    }

    func testBatteryPowerServiceKeepsMissingValuesUnavailable() {
        let snapshot = BatteryPowerService.snapshot(fromPowerSourceDescription: [
            "Power Source State": "Battery Power",
            "Is Charging": false,
            "Time to Empty": 125
        ])

        XCTAssertNil(snapshot.chargePercent)
        XCTAssertEqual(snapshot.isCharging, false)
        XCTAssertEqual(snapshot.powerSource, .batteryPower)
        XCTAssertEqual(snapshot.isConnectedToAC, false)
        XCTAssertEqual(snapshot.isDischarging, true)
        XCTAssertEqual(snapshot.remainingTimeMinutes, 125)
        XCTAssertNil(snapshot.timeToFullChargeMinutes)

        let unavailable = BatteryPowerService.snapshot(fromPowerSourceDescription: [:])
        XCTAssertNil(unavailable.chargePercent)
        XCTAssertNil(unavailable.isCharging)
        XCTAssertEqual(unavailable.powerSource, .unknown)
        XCTAssertNil(unavailable.isConnectedToAC)
        XCTAssertNil(unavailable.remainingTimeMinutes)
    }

    func testNetworkThroughputDividesCounterDeltasByElapsedInterval() {
        let previous = NetworkMonitorSample(
            date: Date(timeIntervalSince1970: 10),
            receivedBytes: 10_000,
            sentBytes: 5_000
        )
        let current = NetworkMonitorSample(
            date: Date(timeIntervalSince1970: 12),
            receivedBytes: 14_096,
            sentBytes: 7_048
        )

        let throughput = SystemMonitorService.networkThroughput(current: current, previous: previous)

        XCTAssertEqual(throughput.downBytesPerSecond, 2048)
        XCTAssertEqual(throughput.upBytesPerSecond, 1024)
    }

    func testNetworkCounterRegressionLeavesThroughputMissing() {
        let start = Date(timeIntervalSince1970: 10)
        let previous = NetworkMonitorSample(
            date: start,
            receivedBytes: 20_000,
            sentBytes: 10_000
        )
        let current = NetworkMonitorSample(
            date: start.addingTimeInterval(2),
            receivedBytes: 100,
            sentBytes: 50
        )

        let throughput = SystemMonitorService.networkThroughput(
            current: current,
            previous: previous
        )

        XCTAssertNil(throughput.downBytesPerSecond)
        XCTAssertNil(throughput.upBytesPerSecond)
    }

    func testPhysicalUplinkFilterKeepsEthernetAndExcludesVirtualInterfaces() {
        XCTAssertTrue(SystemMonitorService.isPhysicalUplinkInterface("en0"))
        XCTAssertTrue(SystemMonitorService.isPhysicalUplinkInterface("en7"))

        for virtualInterface in [
            "lo0", "awdl0", "llw0", "bridge100", "gif0", "stf0",
            "utun5", "ipsec0", "ppp0", "tun1", "tap0", "vnic0",
            "vmnet1", "providervpn0"
        ] {
            XCTAssertFalse(
                SystemMonitorService.isPhysicalUplinkInterface(virtualInterface),
                "\(virtualInterface) must stay out of the physical uplink total"
            )
        }
    }

    func testNativeNetworkInterfacePrefersPrimaryIPv4InterfaceAndFallsBackToWiFi() {
        XCTAssertEqual(
            NativeNetworkInterfaceService.resolvedInterfaceName(
                coreWLANInterfaceName: nil,
                primaryIPv4InterfaceName: "en5"
            ),
            "en5"
        )
        XCTAssertEqual(
            NativeNetworkInterfaceService.resolvedInterfaceName(
                coreWLANInterfaceName: "en0",
                primaryIPv4InterfaceName: "en5"
            ),
            "en5"
        )
        XCTAssertEqual(
            NativeNetworkInterfaceService.resolvedInterfaceName(
                coreWLANInterfaceName: "en0",
                primaryIPv4InterfaceName: "  "
            ),
            "en0"
        )
        XCTAssertNil(
            NativeNetworkInterfaceService.resolvedInterfaceName(
                coreWLANInterfaceName: "  ",
                primaryIPv4InterfaceName: nil
            )
        )
    }

    func testMonitorSnapshotExposesStructuredNetworkThroughput() {
        let previous = NetworkMonitorSample(
            date: Date(timeIntervalSince1970: 10),
            receivedBytes: 10_000,
            sentBytes: 5_000
        )
        let current = NetworkMonitorSample(
            date: Date(timeIntervalSince1970: 12),
            receivedBytes: 14_096,
            sentBytes: 7_048
        )

        let result = SystemMonitorService.buildSnapshot(
            enabledKinds: [.networkSpeed],
            memorySnapshot: nil,
            previousNetworkSample: previous,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: nil,
                thermal: .empty,
                networkSample: current
            ),
            now: current.date
        )

        XCTAssertEqual(
            result.snapshot.networkThroughput,
            NetworkMonitorThroughput(downBytesPerSecond: 2_048, upBytesPerSecond: 1_024)
        )
    }

    func testSMCFanSpeedServiceReadsAllFanActualSpeedKeys() {
        let values = [
            "FNum": 2.0,
            "F0Ac": 2316.4,
            "F1Ac": 2502.6
        ]

        let speeds = SMCFanSpeedService.fanSpeedsRPM { values[$0] }

        XCTAssertEqual(speeds, [2316, 2503])
        XCTAssertEqual(SMCFanSpeedService.averageRPM(from: speeds), 2410)
    }

    func testSMCFanCountDistinguishesFanlessFailedAndStoppedReadings() {
        let cases: [(values: [String: Double], count: Int?, rpm: Int?)] = [
            ([:], nil, nil),
            (["FNum": 0], 0, nil),
            (["FNum": 0.5], nil, nil),
            (["FNum": .nan], nil, nil),
            (["FNum": -1], nil, nil),
            (["FNum": 17], nil, nil),
            (["FNum": 1], 1, nil),
            (["FNum": 1, "F0Ac": .nan], 1, nil),
            (["FNum": 1, "F0Ac": 0], 1, 0),
            (["FNum": 2, "F0Ac": 0, "F1Ac": 2_400], 2, 1_200),
        ]
        for entry in cases {
            let fanCount = SMCFanSpeedService.fanCount { entry.values[$0] }
            let readings = SMCFanSpeedService.fanReadings { entry.values[$0] }
            let speeds = readings.map(\.actualRPM)
            let result = SystemMonitorService.buildSnapshot(
                enabledKinds: [.gpuUsage, .fanSpeed],
                memorySnapshot: nil,
                previousNetworkSample: nil,
                liveReadings: SystemMonitorService.LiveReadings(
                    cpuUsagePercent: nil,
                    thermal: SystemMonitorService.ThermalReadings(
                        gpuUsagePercent: 0,
                        chipTemperatureCelsius: 50,
                        fanSpeedRPM: SMCFanSpeedService.averageRPM(from: speeds),
                        fanCount: fanCount,
                        fanSpeedsRPM: speeds,
                        fanReadings: readings
                    ),
                    networkSample: nil
                ),
                now: Date(timeIntervalSince1970: 1)
            )
            let telemetry = FanTelemetryState.resolve(snapshot: result.snapshot)
            XCTAssertEqual(result.snapshot.fanCount, entry.count)
            XCTAssertEqual(result.snapshot.sensorAvailability, .available)
            XCTAssertEqual(telemetry.isFanless, entry.count == 0)
            XCTAssertEqual(telemetry.actualRPM, entry.rpm)
            XCTAssertEqual(telemetry.telemetryAvailable, entry.rpm != nil)
            XCTAssertFalse(telemetry.isSampling)
            XCTAssertEqual(
                result.snapshot.fanAvailability,
                entry.count == 0 || entry.rpm != nil ? .available : .unavailable
            )
        }
    }

    func testSMCFanSpeedServiceReadsRealMinimumMaximumAndTargetRanges() {
        let values: [String: Double] = [
            "FNum": 1,
            "F0Ac": 2_400,
            "F0Mn": 2_000,
            "F0Mx": 6_000,
            "F0Tg": 2_800
        ]

        let reading = SMCFanSpeedService.fanReadings { values[$0] }.first

        XCTAssertEqual(reading?.actualRPM, 2_400)
        XCTAssertEqual(reading?.minimumRPM, 2_000)
        XCTAssertEqual(reading?.maximumRPM, 6_000)
        XCTAssertEqual(reading?.targetRPM, 2_800)
        XCTAssertEqual(reading?.normalizedPercent ?? -1, 10, accuracy: 0.001)
    }

    func testSMCFanSpeedServiceKeepsFanNameAndSpeedOnTheSameSMCIndex() {
        let values: [String: Double] = [
            "FNum": 2,
            "F0Ac": 2_320,
            "F1Ac": 2_502
        ]
        let names = [
            "F0ID": "Left side",
            "F1ID": "Right side"
        ]

        let readings = SMCFanSpeedService.fanReadings(
            readValue: { values[$0] },
            readName: { names[$0] },
            isPortable: true
        )

        XCTAssertEqual(readings.map(\.index), [0, 1])
        XCTAssertEqual(readings.map(\.identity), [.left, .right])
        XCTAssertEqual(readings.map(\.actualRPM), [2_320, 2_502])
    }

    func testSMCFanSpeedServiceUsesPortableDualFanFallbackOnlyWhenUnambiguous() {
        let values: [String: Double] = [
            "FNum": 2,
            "F0Ac": 2_320,
            "F1Ac": 2_502
        ]

        let portable = SMCFanSpeedService.fanReadings(
            readValue: { values[$0] },
            readName: { _ in nil },
            isPortable: true
        )
        let desktop = SMCFanSpeedService.fanReadings(
            readValue: { values[$0] },
            readName: { _ in nil },
            isPortable: false
        )

        XCTAssertEqual(portable.map(\.identity), [.left, .right])
        XCTAssertEqual(desktop.map(\.identity), [nil, nil])
    }

    func testSMCFanSpeedServiceCompletesSpeedOnlyPortableFanNamesBySMCIndex() {
        let portable = SMCFanSpeedService.resolvedFanReadings(
            nil,
            fallbackSpeeds: [2_315, 2_499],
            isPortable: true
        )
        let desktop = SMCFanSpeedService.resolvedFanReadings(
            nil,
            fallbackSpeeds: [2_315, 2_499],
            isPortable: false
        )

        XCTAssertEqual(portable?.map(\.identity), [.left, .right])
        XCTAssertEqual(portable?.map(\.index), [0, 1])
        XCTAssertEqual(portable?.map(\.actualRPM), [2_315, 2_499])
        XCTAssertEqual(desktop?.map(\.identity), [nil, nil])
    }

    func testSMCFanSpeedServicePreservesReportedIdentityWhileCompletingMissingPeer() {
        let readings = [
            SystemFanReading(
                index: 0,
                identity: .named("Custom Left"),
                actualRPM: 2_315,
                minimumRPM: 1_800,
                maximumRPM: 7_800,
                targetRPM: 2_400
            ),
            SystemFanReading(
                index: 1,
                actualRPM: 2_499,
                minimumRPM: 1_800,
                maximumRPM: 7_800,
                targetRPM: 2_500
            )
        ]

        let resolved = SMCFanSpeedService.resolvedFanReadings(
            readings,
            fallbackSpeeds: nil,
            isPortable: true
        )

        XCTAssertEqual(resolved?.map(\.identity), [.named("Custom Left"), .right])
        XCTAssertEqual(resolved?.map(\.targetRPM), [2_400, 2_500])
    }

    func testSMCFanSpeedServiceDecodesLegacyFanDescriptorPayload() {
        let bytes: [UInt8] = [
            0x01, 0x01, 0x0e, 0x00,
            0x4c, 0x65, 0x66, 0x74, 0x20, 0x73, 0x69, 0x64, 0x65,
            0x00, 0x00, 0x00
        ]

        XCTAssertEqual(
            SMCFanSpeedService.decodeFanName(dataType: "{fds", bytes: bytes),
            "Left side"
        )
    }

    func testSMCFanSpeedServiceKeepsStoppedFansAsZeroRPM() {
        let values = [
            "FNum": 2.0,
            "F0Ac": 0.0,
            "F1Ac": 0.0
        ]

        let speeds = SMCFanSpeedService.fanSpeedsRPM { values[$0] }

        XCTAssertEqual(speeds, [0, 0])
        XCTAssertEqual(SMCFanSpeedService.averageRPM(from: speeds), 0)
    }

    func testSMCFanSpeedServiceRejectsInvalidReadingsAndFanlessHardware() {
        let invalidValues = [
            "FNum": 2.0,
            "F0Ac": -1.0,
            "F1Ac": Double.infinity
        ]
        let partialValues = [
            "FNum": 2.0,
            "F0Ac": 0.0
        ]
        let fanlessValues = ["FNum": 0.0]

        XCTAssertEqual(SMCFanSpeedService.fanSpeedsRPM { invalidValues[$0] }, [])
        XCTAssertEqual(SMCFanSpeedService.fanSpeedsRPM { partialValues[$0] }, [])
        XCTAssertEqual(SMCFanSpeedService.fanSpeedsRPM { fanlessValues[$0] }, [])
    }

    func testFanMetricKeepsZeroRPMAvailableForStoppedFans() {
        let now = Date(timeIntervalSince1970: 20)
        let stoppedFans = SystemMonitorService.buildSnapshot(
            enabledKinds: [.fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: nil,
                thermal: SystemMonitorService.ThermalReadings(
                    gpuUsagePercent: nil,
                    chipTemperatureCelsius: nil,
                    fanSpeedRPM: 0,
                    fanCount: 2
                ),
                networkSample: nil
            ),
            now: now
        )
        let unavailableFans = SystemMonitorService.buildSnapshot(
            enabledKinds: [.fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: nil,
                thermal: .empty,
                networkSample: nil
            ),
            now: now
        )

        let stoppedMetric = stoppedFans.snapshot.metric(for: .fanSpeed)
        XCTAssertEqual(stoppedMetric?.value, "0 rpm")
        XCTAssertEqual(stoppedMetric?.detail, L10n.text("2 个风扇平均", "2 fan average"))
        XCTAssertEqual(stoppedMetric?.isAvailable, true)
        XCTAssertEqual(unavailableFans.snapshot.metric(for: .fanSpeed)?.isAvailable, false)
    }

    func testProcessorAndSensorRowsOmitUnavailableValuesAndKeepZeroRPM() {
        let rows = AdvancedTelemetryRows.make(
            cpuFrequencyGHz: 3.2,
            nominalVoltageMillivolts: 920,
            cpuPowerWatts: nil,
            fanRPM: [0, 2_410]
        )

        XCTAssertTrue(rows.contains(where: { $0.id == "cpu-frequency" }))
        XCTAssertTrue(rows.contains(where: { $0.id == "cpu-voltage" }))
        XCTAssertFalse(rows.contains(where: { $0.id == "cpu-power" }))
        XCTAssertEqual(rows.filter { $0.id.hasPrefix("fan-") }.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "fan-0" })?.value, "0 rpm")
    }

    func testSensorRowsPreserveStructuredFanNamesAndIndexes() {
        let rows = AdvancedTelemetryRows.make(
            cpuFrequencyGHz: nil,
            nominalVoltageMillivolts: nil,
            cpuPowerWatts: nil,
            fanRPM: [9_999, 9_999],
            fanReadings: [
                SystemFanReading(
                    index: 1,
                    identity: .right,
                    actualRPM: 2_502,
                    minimumRPM: 2_317,
                    maximumRPM: 7_826,
                    targetRPM: 2_502
                ),
                SystemFanReading(
                    index: 0,
                    identity: .left,
                    actualRPM: 2_320,
                    minimumRPM: 2_317,
                    maximumRPM: 7_826,
                    targetRPM: 2_317
                )
            ]
        )

        XCTAssertEqual(rows.map(\.id), ["fan-0", "fan-1"])
        XCTAssertEqual(
            rows.map(\.title),
            ["Left Fan", "Right Fan"]
        )
        XCTAssertEqual(rows.map(\.value), ["2,320 rpm", "2,502 rpm"])
    }

    func testTelemetryPointKeepsEachFanHistoryOnItsOriginalSMCIndex() {
        let point = MenuBarTelemetryPoint(
            date: Date(timeIntervalSince1970: 1_000),
            cpuTotal: nil,
            cpuUser: nil,
            cpuSystem: nil,
            gpu: nil,
            memory: nil,
            chipTemperature: nil,
            fanRPM: 2_411,
            fanReadings: [
                SystemFanReading(
                    index: 1,
                    identity: .right,
                    actualRPM: 2_502,
                    minimumRPM: 2_317,
                    maximumRPM: 7_826,
                    targetRPM: 2_502
                ),
                SystemFanReading(
                    index: 0,
                    identity: .left,
                    actualRPM: 2_320,
                    minimumRPM: 2_317,
                    maximumRPM: 7_826,
                    targetRPM: 2_317
                )
            ],
            downBytesPerSecond: nil,
            upBytesPerSecond: nil
        )

        XCTAssertEqual(point.fanRPM(at: 0), 2_320)
        XCTAssertEqual(point.fanRPM(at: 1), 2_502)
        XCTAssertNil(point.fanRPM(at: 2))
        XCTAssertEqual(
            point.replacingFanRPM(with: point.fanRPM(at: 0)).fanRPM,
            2_320
        )
        XCTAssertEqual(SystemFanSpeedFormat.string(2_315), "2,315 rpm")
    }

    func testTelemetryPointKeepsOnlyRealGPUTemperatureAndMigratesLegacyHistory() throws {
        let snapshot = SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_001),
            metrics: [],
            networkThroughput: nil,
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 54.0),
                SystemTemperatureReading(zone: .gpu, celsius: 63.5)
            ]
        )
        let point = MenuBarTelemetryPoint(snapshot: snapshot)

        XCTAssertEqual(point.gpuTemperature, 63.5)
        XCTAssertEqual(MenuBarTelemetryChannel.gpuTemperature.value(in: point), 63.5)
        XCTAssertEqual(MenuBarTelemetryChannel.temperature(.chip).value(in: point), 54)
        XCTAssertEqual(MenuBarTelemetryChannel.temperature(.gpu).value(in: point), 63.5)
        XCTAssertEqual(point.replacingFanRPM(with: 2_000).gpuTemperature, 63.5)
        XCTAssertEqual(point.replacingMemory(with: 42).gpuTemperature, 63.5)

        let chipOnly = MenuBarTelemetryPoint(
            snapshot: SystemMonitorSnapshot(
                generatedAt: snapshot.generatedAt,
                metrics: [],
                networkThroughput: nil,
                temperatureReadings: [
                    SystemTemperatureReading(zone: .chip, celsius: 54.0)
                ]
            )
        )
        XCTAssertNil(chipOnly.gpuTemperature)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(point)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "gpuTemperature")
        legacyObject.removeValue(forKey: "temperatureReadings")
        let legacyPoint = try JSONDecoder().decode(
            MenuBarTelemetryPoint.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacyPoint.gpuTemperature)
        XCTAssertNil(legacyPoint.temperatureReadings)
    }

    func testTelemetryPointKeepsHistoryForEveryReportedTemperatureZone() {
        let readings = SystemTemperatureZone.allCases.enumerated().map { index, zone in
            SystemTemperatureReading(zone: zone, celsius: 30 + Double(index))
        }
        let point = MenuBarTelemetryPoint(
            snapshot: SystemMonitorSnapshot(
                generatedAt: Date(timeIntervalSince1970: 1_002),
                metrics: [],
                networkThroughput: nil,
                temperatureReadings: readings
            )
        )

        XCTAssertEqual(point.temperatureReadings, readings)
        for reading in readings {
            XCTAssertEqual(
                MenuBarTelemetryChannel.temperature(reading.zone).value(in: point),
                reading.celsius
            )
        }
        XCTAssertEqual(point.replacingFanRPM(with: 2_000).temperatureReadings, readings)
        XCTAssertEqual(point.replacingMemory(with: 42).temperatureReadings, readings)
    }

    func testMonitorSnapshotPreservesEveryValidFanSpeed() {
        let temperatures = [
            SystemTemperatureReading(zone: .soc, celsius: 57.2),
            SystemTemperatureReading(zone: .storage, celsius: 42.8)
        ]
        let result = SystemMonitorService.buildSnapshot(
            enabledKinds: [.fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: nil,
                thermal: SystemMonitorService.ThermalReadings(
                    gpuUsagePercent: nil,
                    chipTemperatureCelsius: nil,
                    fanSpeedRPM: 1_205,
                    fanCount: 2,
                    fanSpeedsRPM: [0, 2_410],
                    temperatureReadings: temperatures
                ),
                networkSample: nil
            ),
            now: Date(timeIntervalSince1970: 21)
        )

        XCTAssertEqual(result.snapshot.fanSpeedsRPM, [0, 2_410])
        XCTAssertEqual(result.snapshot.fanCount, 2)
        XCTAssertEqual(result.snapshot.temperatureReadings, temperatures)
        XCTAssertEqual(result.snapshot.sensorAvailability, .available)
    }

    func testSamplerPreservesEveryFanSpeedFromThermalWorker() async throws {
        let expectedSpeeds = [0, 2_410, 2_515]
        let sampler = SystemMonitorSampler(
            temperatureAndFanReader: {
                SystemMonitorService.ThermalReadings(
                    gpuUsagePercent: nil,
                    chipTemperatureCelsius: 61,
                    fanSpeedRPM: 2_515,
                    fanCount: expectedSpeeds.count,
                    fanSpeedsRPM: expectedSpeeds
                )
            }
        )
        let now = Date()

        _ = await sampler.snapshot(
            enabledKinds: [.fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            now: now
        )

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(2))
            let result = await sampler.snapshot(
                enabledKinds: [.fanSpeed],
                memorySnapshot: nil,
                previousNetworkSample: nil,
                now: now
            )
            if result.snapshot.fanSpeedsRPM != nil {
                XCTAssertEqual(result.snapshot.fanSpeedsRPM, expectedSpeeds)
                return
            }
        }

        XCTFail("The real sampler chain never published all fan speeds")
    }

    func testInitialAsyncThermalSampleReportsSamplingUntilDataCompletes() async throws {
        let sampler = SystemMonitorSampler(
            temperatureAndFanReader: {
                SystemMonitorService.ThermalReadings(
                    gpuUsagePercent: nil,
                    chipTemperatureCelsius: 58,
                    fanSpeedRPM: nil,
                    fanCount: nil
                )
            }
        )
        let now = Date()

        let initial = await sampler.snapshot(
            enabledKinds: [.chipTemperature],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            now: now
        )
        XCTAssertEqual(initial.snapshot.sensorAvailability, .sampling)

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(2))
            let result = await sampler.snapshot(
                enabledKinds: [.chipTemperature],
                memorySnapshot: nil,
                previousNetworkSample: nil,
                now: now
            )
            if result.snapshot.sensorAvailability != .sampling {
                XCTAssertEqual(result.snapshot.sensorAvailability, .available)
                return
            }
        }

        XCTFail("The completed thermal sample never became available")
    }

    func testCompletedEmptyThermalSampleReportsUnavailable() async throws {
        let sampler = SystemMonitorSampler(
            temperatureAndFanReader: { .empty }
        )
        let now = Date()

        let initial = await sampler.snapshot(
            enabledKinds: [.chipTemperature, .fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            now: now
        )
        XCTAssertEqual(initial.snapshot.sensorAvailability, .sampling)
        XCTAssertTrue(FanTelemetryState.resolve(snapshot: initial.snapshot).isSampling)

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(2))
            let result = await sampler.snapshot(
                enabledKinds: [.chipTemperature, .fanSpeed],
                memorySnapshot: nil,
                previousNetworkSample: nil,
                now: now
            )
            if result.snapshot.sensorAvailability != .sampling {
                XCTAssertEqual(result.snapshot.sensorAvailability, .unavailable)
                let telemetry = FanTelemetryState.resolve(snapshot: result.snapshot)
                XCTAssertFalse(telemetry.isSampling)
                XCTAssertFalse(telemetry.isFanless)
                XCTAssertFalse(telemetry.telemetryAvailable)
                return
            }
        }

        XCTFail("The completed empty thermal sample never became unavailable")
    }

    func testInteractiveThermalCadenceRefreshesSoonerWithoutParallelReaders() async throws {
        let counter = LockedInvocationCounter()
        let sampler = SystemMonitorSampler(
            temperatureAndFanReader: {
                counter.increment()
                return SystemMonitorService.ThermalReadings(
                    gpuUsagePercent: nil,
                    chipTemperatureCelsius: 58,
                    fanSpeedRPM: 2_100,
                    fanCount: 1
                )
            }
        )
        let start = Date()

        _ = await sampler.snapshot(
            enabledKinds: [.chipTemperature, .fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            thermalSamplingInterval: SystemMonitorSamplingInterval.interactive,
            now: start
        )
        for _ in 0..<100 where counter.value == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(counter.value, 1)

        var initialSampleAvailable = false
        for _ in 0..<100 {
            let result = await sampler.snapshot(
                enabledKinds: [.chipTemperature, .fanSpeed],
                memorySnapshot: nil,
                previousNetworkSample: nil,
                thermalSamplingInterval: SystemMonitorSamplingInterval.interactive,
                now: start
            )
            if result.snapshot.sensorAvailability == .available {
                initialSampleAvailable = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(initialSampleAvailable)

        _ = await sampler.snapshot(
            enabledKinds: [.chipTemperature, .fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            thermalSamplingInterval: SystemMonitorSamplingInterval.interactive,
            now: start.addingTimeInterval(1.9)
        )
        XCTAssertEqual(counter.value, 1)

        _ = await sampler.snapshot(
            enabledKinds: [.chipTemperature, .fanSpeed],
            memorySnapshot: nil,
            previousNetworkSample: nil,
            thermalSamplingInterval: SystemMonitorSamplingInterval.interactive,
            now: start.addingTimeInterval(2.1)
        )
        for _ in 0..<100 where counter.value == 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(counter.value, 2)
    }

    func testGPUPerformanceServicePrefersDeviceUtilization() {
        let usage = GPUPerformanceService.usagePercent(fromPerformanceStatistics: [
            "Device Utilization %": 42.4,
            "Renderer Utilization %": 81.0,
            "Tiler Utilization %": 12.0
        ])

        XCTAssertEqual(usage, 42.4)
    }

    func testGPUPerformanceServiceFallsBackToRendererAndTilerUtilization() {
        let usage = GPUPerformanceService.usagePercent(fromPerformanceStatistics: [
            "Renderer Utilization %": 24.0,
            "Tiler Utilization %": 31.0
        ])

        XCTAssertEqual(usage, 31.0)
    }

    func testGPUPerformanceSnapshotReadsRealUnifiedMemoryCounter() {
        let snapshot = GPUPerformanceService.snapshot(fromPerformanceStatistics: [
            "Device Utilization %": 42.4,
            "In use system memory": 783_007_744
        ])

        XCTAssertEqual(snapshot?.usagePercent, 42.4)
        XCTAssertEqual(snapshot?.memoryUsedBytes, 783_007_744)
    }

    func testAppleSiliconTemperatureServicePrefersRealtimeDieSensors() {
        let readings = [
            AppleSiliconTemperatureService.Reading(name: "gas gauge battery", value: 35.1),
            AppleSiliconTemperatureService.Reading(name: "NAND CH0 temp", value: 44.0),
            AppleSiliconTemperatureService.Reading(name: "PMU tcal", value: 51.82),
            AppleSiliconTemperatureService.Reading(name: "PMU tdie1", value: 57.0),
            AppleSiliconTemperatureService.Reading(name: "PMU tdev8", value: 58.28)
        ]

        XCTAssertEqual(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings), 58.28)
    }

    func testAppleSiliconTemperatureServiceFallsBackToClusterMonitorSensors() {
        let readings = [
            AppleSiliconTemperatureService.Reading(name: "pACC MTR Temp 0", value: 49.2),
            AppleSiliconTemperatureService.Reading(name: "eACC MTR Temp 0", value: 46.4),
            AppleSiliconTemperatureService.Reading(name: "gas gauge battery", value: 35.0)
        ]

        XCTAssertEqual(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings), 49.2)
    }

    func testAppleSiliconTemperatureServiceIgnoresPeripheralTemperatures() {
        let readings = [
            AppleSiliconTemperatureService.Reading(name: "NAND CH0 temp", value: 44.0),
            AppleSiliconTemperatureService.Reading(name: "gas gauge battery", value: 35.1),
            AppleSiliconTemperatureService.Reading(name: "PMU tcal", value: 51.82)
        ]

        XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings))
    }

    func testAppleSiliconTemperatureServiceGroupsOnlyRealRegionalReadings() {
        let readings = [
            AppleSiliconTemperatureService.Reading(name: "PMU tdie1", value: 57.0),
            AppleSiliconTemperatureService.Reading(name: "PMU tdie8", value: 58.2),
            AppleSiliconTemperatureService.Reading(name: "Hottest SOC Sensor", value: 55.0),
            AppleSiliconTemperatureService.Reading(name: "SoC MTR Temp 0", value: 56.0),
            AppleSiliconTemperatureService.Reading(name: "pACC MTR Temp 0", value: 49.2),
            AppleSiliconTemperatureService.Reading(name: "eACC MTR Temp 0", value: 46.4),
            AppleSiliconTemperatureService.Reading(name: "GPU MTR Temp 0", value: 50.5),
            AppleSiliconTemperatureService.Reading(name: "NAND CH0 temp", value: 44.0),
            AppleSiliconTemperatureService.Reading(name: "gas gauge battery", value: 35.1),
            AppleSiliconTemperatureService.Reading(name: "ambient temp", value: 25.4),
            AppleSiliconTemperatureService.Reading(name: "Palm Rest temp", value: 32.3),
            AppleSiliconTemperatureService.Reading(name: "Thunderbolt Left Proximity", value: 40.2),
            AppleSiliconTemperatureService.Reading(name: "Thunderbolt Right Proximity", value: 37.4),
            AppleSiliconTemperatureService.Reading(name: "Wi-Fi Module Temperature", value: 55.6),
            AppleSiliconTemperatureService.Reading(name: "unknown proximity sensor", value: 42.0),
            AppleSiliconTemperatureService.Reading(name: "PMU tcal", value: 51.8),
            AppleSiliconTemperatureService.Reading(name: "ambient invalid", value: 140)
        ]

        XCTAssertEqual(
            AppleSiliconTemperatureService.regionalTemperatures(from: readings),
            [
                SystemTemperatureReading(zone: .chip, celsius: 58.2),
                SystemTemperatureReading(zone: .soc, celsius: 56.0),
                SystemTemperatureReading(zone: .performanceCores, celsius: 49.2),
                SystemTemperatureReading(zone: .efficiencyCores, celsius: 46.4),
                SystemTemperatureReading(zone: .gpu, celsius: 50.5),
                SystemTemperatureReading(zone: .storage, celsius: 44.0),
                SystemTemperatureReading(zone: .battery, celsius: 35.1),
                SystemTemperatureReading(zone: .ambient, celsius: 25.4),
                SystemTemperatureReading(zone: .palmRest, celsius: 32.3),
                SystemTemperatureReading(zone: .thunderboltLeft, celsius: 40.2),
                SystemTemperatureReading(zone: .thunderboltRight, celsius: 37.4),
                SystemTemperatureReading(zone: .wifi, celsius: 55.6)
            ]
        )
    }

    func testSMCFanSpeedServiceUsesRealtimeChipTemperatureSensor() {
        let values = [
            "TCHP": 48.7,
            "TPD0": 55.9,
            "TVDM": 70.4
        ]

        XCTAssertEqual(SMCFanSpeedService.chipTemperatureCelsius { values[$0] }, 55.9)
    }

    func testSMCFanSpeedServiceFallsBackToRealtimeTemperatureSensorWhenPrimaryIsMissing() {
        let values = [
            "TS0P": 52.2,
            "TPD0": 68.5,
            "TVDM": 74.1
        ]

        XCTAssertEqual(SMCFanSpeedService.chipTemperatureCelsius { values[$0] }, 68.5)
    }

    func testSMCFanSpeedServiceUsesProximityOnlyAsLastChipFallback() {
        let values = ["TCHP": 48.7]

        XCTAssertEqual(SMCFanSpeedService.chipTemperatureCelsius { values[$0] }, 48.7)
    }

    func testSMCFanSpeedServiceGroupsM5AndPeripheralTemperatureZones() throws {
        let values: [String: Double] = [
            "Tp00": 62.1, "Tp04": 64.4, "Tp08": 63.2, "Tp0C": 61.8,
            "Tp0O": 60.2, "Tp0R": 63.7, "Tp0U": 62.9, "Tp0X": 61.4,
            "Tp0a": 62.5, "Tp0d": 61.9,
            "Tg0U": 58.2, "Tg0X": 59.8,
            "TaLP": 45.0, "TaRF": 46.2,
            "TB1T": 34.5, "TB2T": 35.1,
            "TH0x": 44.3,
            "TDeL": 31.7, "TDeR": 30.4,
            "TaLT": 40.2, "TaRT": 37.4,
            "TW0P": 55.6
        ]

        let readings = SMCFanSpeedService.temperatureReadings { values[$0] }
        let byZone = Dictionary(uniqueKeysWithValues: readings.map { ($0.zone, $0.celsius) })

        XCTAssertEqual(readings.count, 10)
        XCTAssertEqual(try XCTUnwrap(byZone[.performanceCores]), 63.7, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.superCores]), 64.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.gpu]), 59.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.ambient]), 45.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.battery]), 34.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.storage]), 44.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.palmRest]), 31.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.thunderboltLeft]), 40.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.thunderboltRight]), 37.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byZone[.wifi]), 55.6, accuracy: 0.001)
        XCTAssertEqual(
            SMCFanSpeedService.chipTemperatureCelsius { values[$0] },
            64.4
        )
    }

    func testSMCFanSpeedServiceDoesNotMislabelPartialLegacyKeysAsM5CoreGroups() {
        let values: [String: Double] = [
            "Tp00": 52.0,
            "Tp0O": 54.0,
            "Tg0U": 51.0,
            "TW0P": 43.0
        ]

        XCTAssertEqual(
            SMCFanSpeedService.temperatureReadings { values[$0] },
            [SystemTemperatureReading(zone: .wifi, celsius: 43.0)]
        )
    }

    func testSMCFanSpeedServiceDoesNotPresentM5SSDControllersAsPalmRest() {
        let values: [String: Double] = [
            "Tp00": 52, "Tp04": 52, "Tp08": 52, "Tp0C": 52,
            "Tp0O": 54, "Tp0R": 54, "Tp0U": 54, "Tp0X": 54,
            "Tp0a": 54, "Tp0d": 54,
            "Ts0P": 31.7, "Ts1P": 30.4,
            "TH0x": 44.3
        ]

        let readings = SMCFanSpeedService.temperatureReadings { values[$0] }
        let byZone = Dictionary(uniqueKeysWithValues: readings.map { ($0.zone, $0.celsius) })

        XCTAssertNil(byZone[.palmRest])
        XCTAssertEqual(byZone[.storage], 44.3)
    }

    func testSMCFanSpeedServiceUsesCompleteM5GPUClusterTable() throws {
        let values: [String: Double] = [
            "Tp00": 52, "Tp04": 52, "Tp08": 52, "Tp0C": 52,
            "Tp0O": 54, "Tp0R": 54, "Tp0U": 54, "Tp0X": 54,
            "Tp0a": 54, "Tp0d": 54,
            "Tg08": 58.2, "Tg43": 61.4,
            "Tg1g": 99
        ]

        let readings = SMCFanSpeedService.temperatureReadings { values[$0] }
        let gpu = try XCTUnwrap(readings.first(where: { $0.zone == .gpu }))

        XCTAssertEqual(gpu.celsius, 59.8, accuracy: 0.001)
    }

    func testAppleSiliconTemperatureServiceNormalizesDiscoveredSensorFormats() {
        XCTAssertEqual(
            AppleSiliconTemperatureService.normalizedTemperature(
                rawValue: 14_592,
                sensorName: "PMU tdev1"
            ),
            57
        )
        XCTAssertEqual(
            AppleSiliconTemperatureService.normalizedTemperature(
                rawValue: 58.25,
                sensorName: "PMU tdev8"
            ),
            58.25
        )
        XCTAssertEqual(
            AppleSiliconTemperatureService.normalizedTemperature(
                rawValue: 14_592,
                sensorName: "PMU tdie1"
            ),
            57
        )
        XCTAssertNil(
            AppleSiliconTemperatureService.normalizedTemperature(
                rawValue: 256,
                sensorName: "PMU tdev4"
            )
        )
    }

    func testSMCFanSpeedServiceCanProbeLocalFansWhenAvailable() throws {
        let speeds = SMCFanSpeedService.currentFanSpeedsRPM()
        guard !speeds.isEmpty else {
            throw XCTSkip("This Mac does not expose readable fan speed keys.")
        }

        XCTAssertTrue(speeds.allSatisfy { (0...20_000).contains($0) })
    }

    func testSMCFanSpeedServiceLabelsLocalPortableDualFansWhenAvailable() throws {
        let readings = SMCFanSpeedService.currentFanReadings()
        guard NativeBatteryElectricalService.snapshot() != nil, readings.count == 2 else {
            throw XCTSkip("This Mac is not a readable dual-fan portable.")
        }

        XCTAssertEqual(readings.map(\.identity), [.left, .right])
        XCTAssertEqual(readings.map(\.index), [0, 1])
    }

    func testSystemMonitorThermalSnapshotKeepsLocalPortableFanIdentities() throws {
        let thermal = SystemMonitorService.temperatureAndFanReadings()
        guard NativeBatteryElectricalService.snapshot() != nil,
              thermal.fanReadings?.count == 2 else {
            throw XCTSkip("This Mac is not a readable dual-fan portable.")
        }

        let result = SystemMonitorService.buildSnapshot(
            enabledKinds: MenuBarMetricKind.defaultSelection,
            memorySnapshot: nil,
            previousNetworkSample: nil,
            liveReadings: SystemMonitorService.LiveReadings(
                cpuUsagePercent: nil,
                thermal: thermal,
                networkSample: nil
            ),
            now: Date()
        )

        XCTAssertEqual(thermal.fanReadings?.map(\.identity), [.left, .right])
        XCTAssertEqual(result.snapshot.fanReadings?.map(\.identity), [.left, .right])
        XCTAssertEqual(result.snapshot.fanReadings?.map(\.index), [0, 1])
    }

    func testGPUPerformanceServiceCanProbeLocalUsageWhenAvailable() throws {
        guard let usage = GPUPerformanceService.currentUsagePercent() else {
            throw XCTSkip("This Mac does not expose GPU utilization statistics.")
        }

        XCTAssertTrue((0...100).contains(usage))
    }

    func testSMCFanSpeedServiceCanProbeLocalChipTemperatureWhenAvailable() throws {
        guard let temperature = SMCFanSpeedService.currentChipTemperatureCelsius() else {
            throw XCTSkip("This Mac does not expose readable chip temperature keys.")
        }

        XCTAssertTrue((5...130).contains(temperature))
    }

    func testSMCFanSpeedServiceCanProbeLocalRegionalTemperaturesWhenAvailable() throws {
        let readings = SMCFanSpeedService.currentHardwareReadings().temperatureReadings
        guard !readings.isEmpty else {
            throw XCTSkip("This Mac does not expose mapped regional temperature keys.")
        }

        XCTAssertEqual(Set(readings.map(\.zone)).count, readings.count)
        XCTAssertTrue(readings.allSatisfy { (5...130).contains($0.celsius) })
    }

    func testAppleSiliconTemperatureServiceCanProbeLocalChipTemperatureWhenAvailable() throws {
        guard let temperature = AppleSiliconTemperatureService.currentChipTemperatureCelsius() else {
            throw XCTSkip("This Mac does not expose readable HID chip temperature sensors.")
        }

        XCTAssertTrue((5...130).contains(temperature))
    }

    func testMenuBarSamplingKeepsSelectedCadenceAcrossVisibilityAndStatusIcons() {
        XCTAssertEqual(MenuBarMetricKind.defaultSelection, Set(MenuBarMetricKind.allCases))
        XCTAssertEqual(MenuBarRefreshInterval.defaultValue, .oneSecond)
        for interval in MenuBarRefreshInterval.allCases {
            for mode in MenuBarStatusDisplayMode.allCases {
                for visible in [false, true] {
                    XCTAssertEqual(interval.sleepNanoseconds(panelVisible: visible,
                        statusDisplayMode: mode, customFanControlActive: false, lowPowerMode: false),
                        interval.sleepNanoseconds)
                }
            }
            XCTAssertEqual(interval.memorySnapshotSeconds, interval.seconds)
        }
        XCTAssertEqual(MenuBarRefreshInterval.oneSecond.sleepNanoseconds(panelVisible: false,
            statusDisplayMode: .network, customFanControlActive: false, lowPowerMode: true), 30_000_000_000)
        XCTAssertEqual(MenuBarRefreshInterval.oneSecond.sleepNanoseconds(panelVisible: true,
            statusDisplayMode: .network, customFanControlActive: false, lowPowerMode: true), 1_000_000_000)
        XCTAssertEqual(MenuBarRefreshInterval.fiveSeconds.sleepNanoseconds(panelVisible: false,
            statusDisplayMode: .memory, customFanControlActive: true, lowPowerMode: true), 2_000_000_000)
        XCTAssertEqual(MenuBarRefreshInterval.oneSecond.sleepNanoseconds(panelVisible: false,
            statusDisplayMode: .memory, customFanControlActive: true, lowPowerMode: true), 1_000_000_000)
    }

    @MainActor
    func testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore() {
        let store = ScanStore()
        var storeChangeCount = 0
        var monitorChangeCount = 0
        let storeCancellable = store.objectWillChange.sink { storeChangeCount += 1 }
        let monitorCancellable = store.menuBarMonitorState.objectWillChange.sink { monitorChangeCount += 1 }

        store.menuBarMonitorState.update(
            SystemMonitorSnapshot(
                generatedAt: Date(timeIntervalSince1970: 1),
                metrics: [],
                networkThroughput: nil
            )
        )

        XCTAssertEqual(storeChangeCount, 0)
        XCTAssertEqual(monitorChangeCount, 1)
        XCTAssertEqual(store.menuBarMonitorSnapshot?.generatedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(store.menuBarMonitorState.history.map(\.date), [Date(timeIntervalSince1970: 1)])
        withExtendedLifetime((storeCancellable, monitorCancellable)) {}
    }

    @MainActor
    func testMenuBarMonitorStateKeepsMemorySamplesOnTheirRealTimestamps() {
        let state = MenuBarMonitorState()
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let monitorAt = sampledAt.addingTimeInterval(3)
        let memoryMetric = SystemMonitorMetric(
            kind: .memoryUsage,
            value: "42%",
            detail: "Measured",
            isAvailable: true
        )

        state.update(
            SystemMonitorSnapshot(
                generatedAt: monitorAt,
                metrics: [memoryMetric],
                networkThroughput: nil
            )
        )
        state.recordMemorySample(memoryHistorySnapshot(
            at: sampledAt,
            usedPercent: 42,
            pressureFreePercent: 75,
            compressedBytes: 11_800_150_016,
            swapUsedBytes: 0
        ))
        state.update(
            SystemMonitorSnapshot(
                generatedAt: monitorAt.addingTimeInterval(1),
                metrics: [memoryMetric],
                networkThroughput: nil
            )
        )
        let missingAt = sampledAt.addingTimeInterval(8)
        state.update(
            SystemMonitorSnapshot(
                generatedAt: monitorAt.addingTimeInterval(8),
                metrics: [memoryMetric],
                networkThroughput: nil
            )
        )
        state.recordMemorySample(memoryHistorySnapshot(
            at: missingAt,
            usedPercent: nil,
            pressureFreePercent: nil,
            compressedBytes: nil,
            swapUsedBytes: nil
        ))

        XCTAssertTrue(state.history.allSatisfy { $0.memory == nil })
        XCTAssertEqual(state.memoryHistory.map(\.date), [sampledAt, missingAt])
        XCTAssertEqual(state.memoryHistory.first?.memory, 42)
        XCTAssertEqual(state.memoryHistory.first?.memoryPressure, 25)
        XCTAssertEqual(state.memoryHistory.first?.compressedMemoryBytes, 11_800_150_016)
        XCTAssertEqual(state.memoryHistory.first?.swapUsedBytes, 0)
        XCTAssertNil(state.memoryHistory.last?.memory)
        XCTAssertNil(state.memoryHistory.last?.memoryPressure)
        XCTAssertNil(state.memoryHistory.last?.compressedMemoryBytes)
        XCTAssertNil(state.memoryHistory.last?.swapUsedBytes)
        if let measured = state.memoryHistory.first, let missing = state.memoryHistory.last {
            // UInt64 must be converted numerically, never interpreted as a
            // Double bit pattern by Optional.map(Double.init).
            XCTAssertEqual(MenuBarTelemetryChannel.compressedMemoryBytes.value(in: measured), 11_800_150_016)
            XCTAssertEqual(MenuBarTelemetryChannel.swapUsedBytes.value(in: measured), 0)
            XCTAssertNil(MenuBarTelemetryChannel.compressedMemoryBytes.value(in: missing))
            XCTAssertNil(MenuBarTelemetryChannel.swapUsedBytes.value(in: missing))
            let nonzeroSwap = MenuBarTelemetryPoint(memorySnapshot: memoryHistorySnapshot(
                at: sampledAt, usedPercent: 42, pressureFreePercent: 75,
                compressedBytes: 11_800_150_016, swapUsedBytes: 803_602_432
            ))
            XCTAssertEqual(MenuBarTelemetryChannel.swapUsedBytes.value(in: nonzeroSwap), 803_602_432)
        } else {
            XCTFail("Measured and missing memory history samples must both remain present")
        }
        XCTAssertEqual(
            state.snapshot?.generatedAt,
            monitorAt.addingTimeInterval(8)
        )
    }

    func testMenuBarTelemetryHistoryKeepsOneHourAtFullResolutionAndRetainsTwentyEightDays() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var history = MenuBarTelemetryHistory()

        for offset in 0...130 {
            history.append(telemetryPoint(date: start.addingTimeInterval(Double(offset)), cpuTotal: Double(offset)))
        }

        XCTAssertEqual(history.points.count, 131)
        XCTAssertEqual(history.points.last?.date, start.addingTimeInterval(130))

        history.append(telemetryPoint(date: start.addingTimeInterval(129), cpuTotal: 999))
        XCTAssertEqual(history.points.last?.cpuTotal, 130)
        XCTAssertEqual(
            history.points.first(where: { $0.date == start.addingTimeInterval(129) })?.cpuTotal,
            999
        )
        XCTAssertEqual(history.epoch, 1)
        XCTAssertTrue(history.epochBreaks.contains(start.addingTimeInterval(129)))

        history.append(telemetryPoint(date: start.addingTimeInterval(130), cpuTotal: 88))
        XCTAssertEqual(history.points.count, 131)
        XCTAssertEqual(history.points.last?.cpuTotal, 88)

        var twoHours = MenuBarTelemetryHistory()
        for second in 0...(2 * 60 * 60) {
            twoHours.append(telemetryPoint(
                date: start.addingTimeInterval(Double(second)),
                cpuTotal: Double(second)
            ))
        }
        XCTAssertLessThan(twoHours.points.count, 3_720)
        XCTAssertEqual(
            twoHours.points.suffix(3_601).map(\.date),
            (3_600...7_200).map { start.addingTimeInterval(Double($0)) }
        )

        var retained = MenuBarTelemetryHistory()
        for minute in 0...MenuBarHistoryRetention.maximumMinutePointCount {
            retained.append(telemetryPoint(
                date: start.addingTimeInterval(Double(minute) * 60),
                cpuTotal: Double(minute)
            ))
        }

        XCTAssertEqual(retained.points.count, MenuBarHistoryRetention.maximumMinutePointCount)
        XCTAssertEqual(retained.points.first?.date, start.addingTimeInterval(60))
        XCTAssertEqual(
            retained.points.last?.date,
            start.addingTimeInterval(Double(MenuBarHistoryRetention.maximumMinutePointCount) * 60)
        )

        let selected = MenuBarHistoryRetention.selected(
            retained.points,
            duration: MenuBarHistoryRetention.duration,
            date: \.date,
            referenceDate: retained.points.last!.date
        )
        XCTAssertEqual(selected.count, retained.points.count)
        XCTAssertEqual(selected.first?.date, retained.points.first?.date)
        XCTAssertEqual(selected.last?.date, retained.points.last?.date)
    }

    func testTelemetryHistoryPreservesBackwardAndForwardEpochSamples() {
        let start = Date(timeIntervalSinceReferenceDate: 60_000)
        var history = MenuBarTelemetryHistory()
        history.append(telemetryPoint(date: start, cpuTotal: 1))
        history.append(telemetryPoint(date: start.addingTimeInterval(1), cpuTotal: 2))

        history.append(telemetryPoint(
            date: start.addingTimeInterval(-10),
            cpuTotal: 3
        ))
        XCTAssertEqual(history.epoch, 1)
        XCTAssertTrue(history.points.contains { $0.cpuTotal == 3 })
        XCTAssertEqual(history.points.map(\.date), history.points.map(\.date).sorted())

        history.append(telemetryPoint(
            date: start.addingTimeInterval(120),
            cpuTotal: 4
        ))
        XCTAssertEqual(history.epoch, 2)
        XCTAssertEqual(history.points.last?.cpuTotal, 4)
        XCTAssertEqual(history.epochBreaks.count, 2)
    }

    func testTelemetryHistoryRestoreKeepsSamplesAcrossPanelReconstruction() {
        let start = Date(timeIntervalSinceReferenceDate: 70_000)
        var original = MenuBarTelemetryHistory()
        original.append(telemetryPoint(date: start, cpuTotal: 10))
        original.append(telemetryPoint(date: start.addingTimeInterval(1), cpuTotal: 11))

        var reopened = MenuBarTelemetryHistory()
        reopened.restore(original.points)
        XCTAssertEqual(reopened.points, original.points)

        reopened.append(telemetryPoint(date: start.addingTimeInterval(2), cpuTotal: 12))
        XCTAssertEqual(reopened.points.map(\.cpuTotal), [10, 11, 12])
    }

    func testMenuBarHistorySelectionKeepsEveryRealTimestampForChartBuckets() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let points = (0...720).map { index in
            let fraction = Double(index) / 720
            return telemetryPoint(
                date: start.addingTimeInterval(fraction * fraction * 120),
                cpuTotal: index == 1 ? 99 : 1
            )
        }

        let selected = MenuBarHistoryRetention.selected(
            points,
            duration: 120,
            date: \.date,
            referenceDate: points.last!.date
        )

        XCTAssertEqual(selected.map(\.date), points.map(\.date))
        XCTAssertEqual(selected[1].cpuTotal, 99)
    }

    func testMenuBarTelemetryGeometryUsesTimestampsAndBreaksMissingSamples() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let segments = MenuBarChartGeometry.pointSegments(
            samples: [
                MenuBarChartSample(date: start, value: 10),
                MenuBarChartSample(date: start.addingTimeInterval(1), value: 20),
                MenuBarChartSample(date: start.addingTimeInterval(2), value: nil),
                MenuBarChartSample(date: start.addingTimeInterval(3), value: 30),
                MenuBarChartSample(date: start.addingTimeInterval(10), value: 40)
            ],
            size: CGSize(width: 100, height: 50),
            valueRange: 0...100,
            verticalPadding: 0
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(try XCTUnwrap(segments.first?.first).x, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments.first?.last).x, 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments.dropFirst().first?.first).x, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments.last?.last).x, 100, accuracy: 0.001)
    }

    func testMenuBarTelemetryNiceCeilingAddsReadableHeadroom() {
        XCTAssertEqual(MenuBarChartGeometry.niceCeiling(for: []), 1)
        XCTAssertEqual(MenuBarChartGeometry.niceCeiling(for: [9]), 10)
        XCTAssertEqual(MenuBarChartGeometry.niceCeiling(for: [100]), 125)
        XCTAssertEqual(MenuBarChartGeometry.niceCeiling(for: [1_900]), 2_500)
    }

    @MainActor
    func testMenuBarStatusRendererKeepsReferenceDimensions() throws {
        let image = MenuBarStatusRenderer.image(for: nil)

        XCTAssertEqual(image.size.width, 54)
        XCTAssertEqual(image.size.height, 24)
        XCTAssertTrue(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
        XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
    }

    @MainActor
    func testMenuBarStatusDisplayModesRenderTemplateImagesAtMenuBarHeight() throws {
        // The default memory mode must stay byte-identical to the reference
        // single-mode layout so existing status items do not shift.
        let memory = MenuBarStatusRenderer.image(for: nil, mode: .memory)
        XCTAssertEqual(memory.size.width, 54)

        for mode in MenuBarStatusDisplayMode.allCases {
            let image = MenuBarStatusRenderer.image(for: nil, mode: mode)
            XCTAssertEqual(image.size.height, 24, mode.rawValue)
            XCTAssertEqual(image.isTemplate, mode != .deviceStatus, mode.rawValue)
            XCTAssertGreaterThanOrEqual(image.size.width, mode == .deviceStatus ? 28 : 30, mode.rawValue)
            XCTAssertNotNil(image.tiffRepresentation, mode.rawValue)
        }
    }

    func testMenuBarStatusDisplayModePersistsAndDefaultsToDeviceStatus() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))

        XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), .deviceStatus)

        MenuBarStatusDisplayMode.network.save(in: defaults)
        XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), .network)

        defaults.set("not-a-mode", forKey: MenuBarStatusDisplayMode.defaultsKey)
        XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), .deviceStatus)
    }

    func testLightweightMemoryStatusSnapshotSkipsProcessEnumeration() async {
        let snapshot = await MemoryOptimizerService.statusSnapshot()

        XCTAssertGreaterThan(snapshot.physicalBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.usedBytes, 0)
        XCTAssertTrue(snapshot.topProcesses.isEmpty)
        // The status path must preserve readable headroom without enumerating apps.
        if let output = try? Shell.capture("/usr/bin/memory_pressure", ["-Q"], timeout: 2),
           MemoryOptimizerService.pressureSummary(from: output).freePercentage != nil {
            XCTAssertNotNil(snapshot.pressureFreePercentage)
        }
        if let percentage = snapshot.pressureFreePercentage {
            XCTAssertTrue((0...100).contains(percentage))
        }
        XCTAssertFalse(snapshot.pressureSummary.isEmpty)
    }

    func testStorageCapacitySnapshotClassifiesAvailableSpace() {
        let healthy = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 300)
        XCTAssertEqual(healthy.usedBytes, 700)
        XCTAssertEqual(healthy.availablePercent, 30)
        XCTAssertEqual(healthy.pressure, .normal)

        let attention = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 150)
        XCTAssertEqual(attention.pressure, .attention)

        let critical = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 50)
        XCTAssertEqual(critical.pressure, .critical)

        let clamped = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 1_500)
        XCTAssertEqual(clamped.availableBytes, 1_000)
        XCTAssertEqual(clamped.usedBytes, 0)
    }

    func testStorageCapacitySnapshotSeparatesStrictAndUserVisibleCapacity() {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: 300,
            availableForImportantUsageBytes: 450
        )

        XCTAssertEqual(snapshot.availableBytes, 300)
        XCTAssertEqual(snapshot.usedBytes, 700)
        XCTAssertEqual(snapshot.userAvailableBytes, 450)
        XCTAssertEqual(snapshot.userUsedBytes, 550)
        XCTAssertEqual(snapshot.reclaimableEstimateBytes, 150)
        XCTAssertEqual(snapshot.userAvailableRatio, 0.45, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.userUsedRatio, 0.55, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.userAvailablePercent, 45)
        XCTAssertEqual(snapshot.userUsedPercent, 55)
        XCTAssertEqual(snapshot.pressure, .normal)
    }

    func testStorageCapacitySnapshotUserCapacityFallsBackToStrictFreeSpace() {
        let missingImportant = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: 300
        )
        XCTAssertEqual(missingImportant.userAvailableBytes, 300)
        XCTAssertEqual(missingImportant.userUsedBytes, 700)
        XCTAssertEqual(missingImportant.reclaimableEstimateBytes, 0)

        let lowerImportant = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: 300,
            availableForImportantUsageBytes: 50
        )
        XCTAssertEqual(lowerImportant.userAvailableBytes, 300)
        XCTAssertEqual(lowerImportant.userUsedBytes, 700)
        XCTAssertEqual(lowerImportant.reclaimableEstimateBytes, 0)
        XCTAssertEqual(lowerImportant.pressure, .critical)
    }

    func testStorageCapacitySnapshotClampsUserCapacityMetrics() {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: -100,
            availableForImportantUsageBytes: 1_500
        )

        XCTAssertEqual(snapshot.availableBytes, 0)
        XCTAssertEqual(snapshot.availableForImportantUsageBytes, 1_000)
        XCTAssertEqual(snapshot.userAvailableBytes, 1_000)
        XCTAssertEqual(snapshot.userUsedBytes, 0)
        XCTAssertEqual(snapshot.reclaimableEstimateBytes, 1_000)
        XCTAssertEqual(snapshot.userAvailableRatio, 1)
        XCTAssertEqual(snapshot.userUsedRatio, 0)
        XCTAssertEqual(snapshot.userAvailablePercent, 100)
        XCTAssertEqual(snapshot.userUsedPercent, 0)
    }

    func testStorageByteFormatUsesDecimalFileStyle() {
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(
            ByteFormat.storageString(1_000_000_000, locale: locale),
            "1 GB"
        )
        XCTAssertEqual(
            ByteFormat.storageString(1_073_741_824, locale: locale),
            "1.07 GB"
        )
        XCTAssertEqual(ByteFormat.string(1_073_741_824), "1.0 GiB")
    }

    func testStorageCapacityServiceReadsStartupVolumeWithoutShellingOut() throws {
        let snapshot = try XCTUnwrap(StorageCapacityService.snapshot())
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.availableBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }

    func testStorageCapacityServiceRequestsReclaimableSpaceOnlyForStartupVolume() {
        XCTAssertTrue(StorageCapacityService.resourceKeys(path: "/Users/example", isInternalVolume: true)
            .contains(.volumeAvailableCapacityForImportantUsageKey))
        XCTAssertFalse(StorageCapacityService.resourceKeys(path: "/Volumes/Network", isInternalVolume: false)
            .contains(.volumeAvailableCapacityForImportantUsageKey))
        XCTAssertTrue(
            StorageCapacityService.resourceKeys(path: "/")
                .contains(.volumeAvailableCapacityForImportantUsageKey)
        )
        XCTAssertFalse(
            StorageCapacityService.resourceKeys(path: "/Volumes/External")
                .contains(.volumeAvailableCapacityForImportantUsageKey)
        )
    }

    func testStorageCapacityReadFailureIsNotAFullDisk() throws {
        XCTAssertNil(StorageCapacityService.measuredSnapshot(total: 1_000, available: nil))
        XCTAssertNil(StorageCapacityService.measuredSnapshot(total: 1_000, available: -1))
        let full = try XCTUnwrap(StorageCapacityService.measuredSnapshot(total: 1_000, available: 0))
        XCTAssertEqual(full.availableBytes, 0)
        XCTAssertEqual(full.userUsedPercent, 100)
        let readable = try XCTUnwrap(StorageCapacityService.measuredSnapshot(total: 1_000, available: 400))
        XCTAssertEqual(readable.availableBytes, 400)
    }

    func testMenuBarStatusViewUsesCompactTabbedSystemLayout() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Models/SystemMonitorModels.swift"),
            encoding: .utf8
        )
        let panelSettingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift"),
            encoding: .utf8
        )
        let chromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"),
            encoding: .utf8
        )
        let chartSamplingSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/PanelChartSampling.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(MenuBarMetricKind.allCases.count, 6)
        XCTAssertTrue(source.contains("CPU"))
        XCTAssertTrue(source.contains("内存"))
        XCTAssertTrue(source.contains("温度"))
        XCTAssertTrue(source.contains("磁盘"))
        XCTAssertTrue(source.contains("网络"))
        XCTAssertFalse(source.contains("StorageCapacityService.snapshot()"))
        XCTAssertTrue(source.contains("auxiliaryState.registerConsumer("))
        XCTAssertFalse(source.contains("menuBar.showHardwareDetails"))
        XCTAssertFalse(source.contains("显示硬件详情"))
        XCTAssertTrue(chromeSource.contains("MenuBarRefreshInterval.allCases"))
        XCTAssertFalse(source.contains("MenuBarPanelSize.allCases"))
        XCTAssertFalse(source.contains("MenuBarSection.allCases"))
        XCTAssertFalse(source.contains("MenuBarProcessLimit.allCases"))
        XCTAssertFalse(source.contains("显示区域"))
        XCTAssertFalse(source.contains("应用数量"))
        XCTAssertFalse(source.contains("小窗宽度"))
        XCTAssertFalse(source.contains("选择显示项"))
        XCTAssertFalse(storeSource.contains("menuBar.metricSelection"))
        XCTAssertFalse(storeSource.contains("menuBar.panelSize"))
        XCTAssertFalse(storeSource.contains("menuBar.sectionSelection"))
        XCTAssertFalse(storeSource.contains("menuBar.processLimit"))
        XCTAssertFalse(modelSource.contains("enum MenuBarPanelSize"))
        XCTAssertFalse(modelSource.contains("enum MenuBarSection"))
        XCTAssertFalse(modelSource.contains("enum MenuBarProcessLimit"))
        XCTAssertTrue(storeSource.contains("let enabledKinds = MenuBarMetricKind.defaultSelection"))
        XCTAssertTrue(modelSource.contains("struct NetworkMonitorThroughput"))
        XCTAssertTrue(modelSource.contains("let networkThroughput: NetworkMonitorThroughput?"))
        XCTAssertTrue(source.contains("store.toggleMenuBarRefreshPaused()"))
        XCTAssertTrue(source.contains("store.refreshMenuBarNow()"))
        XCTAssertTrue(source.contains("private var memoryTint: Color"))
        XCTAssertFalse(source.contains(".task(id: store.menuBarRefreshInterval)"))
        XCTAssertTrue(controllerSource.contains("private var refreshTask: Task<Void, Never>?"))
        XCTAssertTrue(controllerSource.contains("private weak var store: ScanStore?"))
        XCTAssertTrue(controllerSource.contains("interval.sleepNanoseconds("))
        XCTAssertTrue(controllerSource.contains("panelVisible: panelVisible"))
        XCTAssertTrue(controllerSource.contains("panelSession?.panel.isVisible == true"))
        XCTAssertTrue(controllerSource.contains("guard !store.isMenuBarRefreshPaused else { continue }"))
        XCTAssertTrue(controllerSource.contains("PanelScene("))
        XCTAssertTrue(controllerSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertTrue(rootSource.contains("struct PanelScene: View"))
        XCTAssertFalse(rootSource.contains("MenuBarStatusView("))
        XCTAssertTrue(rootSource.contains("presentation: .geek"))
        XCTAssertTrue(sessionSource.contains("panel.contentViewController = nil"))
        XCTAssertFalse(controllerSource.contains("NSPopover"))
        XCTAssertTrue(source.contains("store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)"))
        XCTAssertFalse(source.contains("refreshMenuBarLiveStatus(showLoadingWhenEmpty: false, forceMemorySnapshot: true)"))
        XCTAssertTrue(controllerSource.contains("store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)"))
        XCTAssertFalse(source.contains("Timer.publish(every: 1"))
        XCTAssertFalse(controllerSource.contains("Timer.publish(every: 1"))
        XCTAssertTrue(source.contains("PanelShell(density: .simple, showsNavigation: false)"))
        XCTAssertFalse(source.contains(".frame(width: 360, height: 300)"))
        XCTAssertFalse(source.contains(".frame(height: 204, alignment: .top)"))
        XCTAssertFalse(controllerSource.contains("NSSize(width: 360, height: 300)"))
        XCTAssertFalse(source.contains(".frame(width: 384)"))
        XCTAssertFalse(source.contains(".frame(width: 408)"))
        XCTAssertTrue(modelSource.contains("L10n.text(\"系统\", \"System\")"))
        XCTAssertTrue(modelSource.contains("L10n.text(\"清理\", \"Cleanup\")"))
        XCTAssertTrue(source.contains("panelSettingsState.selectedSection"))
        XCTAssertTrue(source.contains("panelSettingsState.selectSection(section)"))
        XCTAssertFalse(source.contains("@State private var selectedTab"))
        XCTAssertTrue(source.contains("private var cleanupPage: some View"))
        XCTAssertTrue(source.contains("扫描缓存与开发文件"))
        XCTAssertTrue(source.contains("分析磁盘空间"))
        XCTAssertTrue(source.contains("store.startScanRespectingAccessGuide()"))
        XCTAssertTrue(source.contains("store.items(for: .green).filter(\\.canMoveToTrash)"))
        XCTAssertTrue(source.contains(".prefix(2)"))
        XCTAssertTrue(source.contains("MenuBarCleanupGroupRow"))
        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains(".scrollIndicators(.hidden)"))
        let cleanupPageSource = try XCTUnwrap(
            source.components(separatedBy: "private var cleanupPage: some View").last?
                .components(separatedBy: "private var cleanupOverview: some View").first
        )
        XCTAssertFalse(cleanupPageSource.contains("Spacer(minLength: 0)"))
        let systemPageSource = try XCTUnwrap(
            source.components(separatedBy: "private var systemStatusPage: some View").last?
                .components(separatedBy: "private var networkSummaryRow: some View").first
        )
        XCTAssertTrue(systemPageSource.contains("LazyVGrid(columns: systemMetricColumns"))
        XCTAssertTrue(systemPageSource.contains("MenuBarStatusMetricCell("))
        XCTAssertEqual(systemPageSource.components(separatedBy: "GeekPrecisionNetworkChart(").count - 1, 1)
        XCTAssertFalse(source.contains("MenuBarPrimaryMetric"))
        XCTAssertFalse(source.contains("MenuBarCompactMetric"))
        XCTAssertTrue(source.contains("private var systemStatusMetrics: [MenuBarStatusMetric]"))
        let compactMetricsSource = try XCTUnwrap(
            source.components(separatedBy: "private var systemStatusMetrics: [MenuBarStatusMetric]").last?
                .components(separatedBy: "private func systemStatusMetric").first
        )
        XCTAssertEqual(compactMetricsSource.components(separatedBy: "systemStatusMetric(").count - 1, 3)
        XCTAssertEqual(compactMetricsSource.components(separatedBy: "MenuBarStatusMetric(").count - 1, 1)
        XCTAssertTrue(compactMetricsSource.contains("for: .cpuUsage"))
        XCTAssertTrue(compactMetricsSource.contains("for: .memoryUsage"))
        XCTAssertTrue(compactMetricsSource.contains("for: .chipTemperature"))
        XCTAssertTrue(compactMetricsSource.contains("id: \"storage\""))
        XCTAssertFalse(compactMetricsSource.contains(".gpuUsage"))
        XCTAssertFalse(compactMetricsSource.contains(".fanSpeed"))
        XCTAssertTrue(source.contains("count: 4"))
        XCTAssertFalse(source.contains("private var storageSummaryRow: some View"))
        XCTAssertTrue(source.contains("private var networkSummaryRow: some View"))
        XCTAssertTrue(source.contains("GeekPrecisionNetworkChart("))
        XCTAssertTrue(source.contains("PanelCircularGauge("))
        XCTAssertTrue(source.contains("points: monitorState.history"))
        XCTAssertFalse(source.contains("networkHistory"))
        XCTAssertTrue(source.contains("MenuBarNetworkPalette.download"))
        XCTAssertTrue(source.contains("MenuBarNetworkPalette.upload"))
        let networkTextSource = try XCTUnwrap(
            source.components(separatedBy: "private func networkMetricText").last?
                .components(separatedBy: "@ViewBuilder\n    private var recommendationSection").first
        )
        XCTAssertEqual(networkTextSource.components(separatedBy: ".font(MenuBarTypography.metricValue)").count - 1, 1)
        XCTAssertEqual(networkTextSource.components(separatedBy: ".foregroundStyle(tint)").count - 1, 1)
        XCTAssertTrue(source.contains("private typealias MenuBarTypography = MenuBarPanelTypography"))
        XCTAssertFalse(source.contains("private enum MenuBarTypography"))
        XCTAssertFalse(source.contains("static let primaryMetric"))
        XCTAssertFalse(source.contains("static let metricValue: Font = .system(size:"))
        XCTAssertFalse(source.contains("static let value: Font = .system(size:"))
        XCTAssertFalse(source.contains("static let caption: Font = .system(size:"))
        XCTAssertFalse(source.contains("AppDesignTokens.Typography"))
        XCTAssertFalse(source.contains("size: 9.5"))
        XCTAssertFalse(source.contains("size: 10.5"))
        XCTAssertFalse(source.contains("size: 11.5"))
        XCTAssertTrue(source.contains("$0.canQuit && $0.bundlePath?.hasSuffix(\".app\") == true"))
        XCTAssertTrue(source.contains("可退出应用"))
        XCTAssertFalse(source.contains("暂无可退出应用"))
        XCTAssertFalse(source.contains("系统进程只读"))
        XCTAssertTrue(source.contains("snapshot?.recommendedQuitApps"))
        XCTAssertTrue(source.contains(".prefix(3)"))
        XCTAssertTrue(source.contains("store.performRecommendedMemoryAction(presentConfirmationInMenuBar: true)"))
        let compactProcessIconSource = try XCTUnwrap(
            source.components(separatedBy: "private struct MenuBarProcessIcon: View").last
        )
        XCTAssertTrue(compactProcessIconSource.contains("CachedAppIconView("))
        XCTAssertFalse(compactProcessIconSource.contains("AppIconCache.icon(forFile:"))
        XCTAssertFalse(compactProcessIconSource.contains("FileManager.default.fileExists"))
        XCTAssertTrue(source.contains("合并 \\(app.processCount) 个进程"))
        XCTAssertFalse(source.contains("Mac 状态"))
        XCTAssertFalse(source.contains("private var healthTitle: String"))
        XCTAssertFalse(source.contains("private struct MenuBarHealthGauge"))
        XCTAssertFalse(source.contains("摄像头"))
        XCTAssertFalse(source.contains("麦克风"))
        XCTAssertFalse(source.contains("Image(systemName: \"laptopcomputer\")"))
        XCTAssertFalse(source.contains("这台 Mac"))
        XCTAssertFalse(source.contains("AppIconArtwork"))
        XCTAssertFalse(source.contains("GlassAppBackdrop"))
        XCTAssertFalse(source.contains("MenuBarPanelBackdrop"))
        XCTAssertTrue(source.contains("PanelShell(density: .simple"))
        XCTAssertFalse(source.contains("LinearGradient("))
        XCTAssertFalse(source.contains("MenuBarSurfaceModifier"))
        XCTAssertFalse(source.contains("MenuBarIconButtonStyle"))
        XCTAssertFalse(source.contains("MenuBarOpenButtonStyle"))
        XCTAssertTrue(source.contains("PanelHeader("))
        XCTAssertEqual(chromeSource.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertEqual(chromeSource.components(separatedBy: "Menu {").count - 1, 2)
        XCTAssertTrue(chromeSource.contains("struct PanelRefreshControl: View"))
        XCTAssertTrue(chromeSource.contains("AppSymbols.Action.resume"))
        XCTAssertTrue(chromeSource.contains("AppSymbols.Action.refresh"))
        XCTAssertTrue(chromeSource.contains("AppSymbols.Action.more"))
        XCTAssertFalse(source.contains(".contentTransition(.numericText())"))
        XCTAssertTrue(source.contains(
            "AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion)"
        ))
        XCTAssertFalse(source.contains(".snappy(duration: 0.30)"))
        XCTAssertTrue(chromeSource.contains(
            ".accessibilityLabel(L10n.text(\"小窗分区\", \"Panel Section\"))"
        ))
        XCTAssertTrue(source.contains(".monospacedDigit()"))
        XCTAssertFalse(source.contains("transaction.animation = nil"))
        XCTAssertFalse(panelSettingsSource.contains("退出存储清理助手"))
        XCTAssertFalse(panelSettingsSource.contains("NSApp.terminate"))
        XCTAssertTrue(source.contains("case currentScan(Date)"))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"打开主窗口\", \"Open Main Window\")"))
        XCTAssertFalse(source.contains(".appGlassSegmentedControl()"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(chartSamplingSource.contains("static let minimumRenderableSampleCount = 2"))
        XCTAssertTrue(chartSamplingSource.contains("PanelChartSamplingPlaceholder"))
    }

    func testGeekOnlyPanelKeepsRealDataAndSharesOneWindowSession() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let advancedSource = try advancedPanelSource(projectRoot: projectRoot)
        let compactSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"),
            encoding: .utf8
        )
        let panelSettingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift"),
            encoding: .utf8
        )
        let chromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let auxiliaryMonitorSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift"),
            encoding: .utf8
        )
        let telemetryModelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Models/MenuBarTelemetryModels.swift"),
            encoding: .utf8
        )
        let tertiaryDetailSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
            ),
            encoding: .utf8
        )
        let systemModelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Models/SystemMonitorModels.swift"),
            encoding: .utf8
        )
        let telemetryChartSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarTelemetryChart.swift"),
            encoding: .utf8
        )
        let geometrySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/PanelGeometryStore.swift"),
            encoding: .utf8
        )
        let statusPanelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusPanel.swift"),
            encoding: .utf8
        )
        let chartSamplingSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/PanelChartSampling.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(PanelDensity.allCases, [.simple, .complex, .geek])
        XCTAssertEqual(PanelDensity.menuBarChoices, [.geek])
        XCTAssertEqual(PanelDensity.defaultValue, .geek)
        XCTAssertEqual(PanelDensity.stored(in: UserDefaults(suiteName: UUID().uuidString)!), .geek)
        XCTAssertFalse(chromeSource.contains("Picker(L10n.text(\"面板模式\""))
        XCTAssertFalse(chromeSource.contains("ForEach(PanelDensity.menuBarChoices)"))
        XCTAssertFalse(panelSettingsSource.contains("struct PanelSettingsView: View"))
        XCTAssertFalse(panelSettingsSource.contains("Form {"))
        XCTAssertTrue(controllerSource.contains("private let geometryStore = PanelGeometryStore()"))
        XCTAssertTrue(controllerSource.contains("panelSession?.selectDensity(density)"))
        XCTAssertEqual(controllerSource.components(separatedBy: "MenuBarPanelSession(").count - 1, 1)
        XCTAssertFalse(controllerSource.contains("panelSession?.resize(contentSize:"))
        XCTAssertTrue(controllerSource.contains("panelSession?.setGeekSection(section)"))
        XCTAssertTrue(geometrySource.contains("case .simple: NSSize(width: 420, height: 280)"))
        XCTAssertTrue(geometrySource.contains(
            "case .complex, .geek: MiniWindowStyleTokens.overviewSize"
        ))
        XCTAssertTrue(geometrySource.contains("var minimumSize: NSSize {\n        idealSize"))
        XCTAssertFalse(statusPanelSource.contains(".resizable"))
        XCTAssertTrue(sessionSource.contains("geometryStore.save(frame: persistableFrame, for: density)"))
        XCTAssertTrue(sessionSource.contains("func setGeekSection("))
        XCTAssertTrue(sessionSource.contains("_ section: PanelSection"))
        XCTAssertFalse(sessionSource.contains("func windowDidResize"))
        XCTAssertTrue(rootSource.contains("struct PanelScene: View"))
        XCTAssertFalse(rootSource.contains("case .simple:"))
        XCTAssertFalse(rootSource.contains("MenuBarStatusView("))
        XCTAssertFalse(rootSource.contains("case .complex, .geek:"))
        XCTAssertTrue(rootSource.contains("MenuBarAdvancedStatusView("))
        XCTAssertTrue(rootSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertFalse(rootSource.contains("case .geek:"))
        XCTAssertFalse(rootSource.contains("presentation: panelDensity"))
        XCTAssertFalse(rootSource.contains("presentation: .complex"))
        XCTAssertTrue(rootSource.contains("presentation: .geek"))
        XCTAssertFalse(rootSource.contains(".normalizedForMenuBar"))
        XCTAssertFalse(rootSource.contains("migrateLegacyPanelModeIfNeeded()"))
        XCTAssertTrue(sessionSource.contains("panel.contentViewController = nil"))
        XCTAssertFalse(compactSource.contains(".frame(width: 360, height: 300)"))
        XCTAssertFalse(compactSource.contains(".frame(height: 204, alignment: .top)"))
        XCTAssertTrue(compactSource.contains("PanelShell(density: .simple"))
        XCTAssertTrue(advancedSource.contains("density: presentation"))
        XCTAssertTrue(advancedSource.contains("GeekAttachedPanelShell("))
        XCTAssertTrue(advancedSource.contains("section: selectedSection"))
        XCTAssertTrue(advancedSource.contains("onHoverChange: geekAttachedPanelHoverChanged"))
        XCTAssertTrue(advancedSource.contains("showsHeader: !hidesChrome"))
        XCTAssertTrue(advancedSource.contains("showsNavigation: !hidesChrome"))
        XCTAssertFalse(advancedSource.contains("case .window"))
        XCTAssertFalse(appSource.contains("AdvancedMonitorWindowCoordinator"))
        XCTAssertFalse(appSource.contains("AdvancedMonitorWindowView("))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Views/AdvancedMonitorWindowView.swift")
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Support/AdvancedMonitorWindowCoordinator.swift")
                .path
        ))
        XCTAssertTrue(advancedSource.contains("GeekDashboardConfiguration"))
        XCTAssertTrue(advancedSource.contains("GeekDashboardLayoutPlanner.rows"))
        XCTAssertTrue(advancedSource.contains("GeekDashboardEditor"))
        XCTAssertFalse(advancedSource.contains("高级监控"))
        XCTAssertFalse(advancedSource.contains("Advanced Monitor"))
        XCTAssertFalse(advancedSource.contains("geekWorkspace"))
        XCTAssertFalse(advancedSource.contains("geekModuleRail"))
        XCTAssertTrue(advancedSource.contains("var moduleRail: some View"))
        XCTAssertTrue(advancedSource.contains("PanelHeader("))
        XCTAssertTrue(advancedSource.contains("geekDetailPage"))
        XCTAssertFalse(advancedSource.contains(".frame(height: presentation.contentHeight)"))
        XCTAssertTrue(advancedSource.contains("ScrollView(.vertical)"))
        XCTAssertFalse(advancedSource.contains("var geekFooter: some View"))
        XCTAssertTrue(advancedSource.contains("openApp(filter: .overview)"))
        XCTAssertFalse(advancedSource.contains("toggleSettingsPresentation()"))
        XCTAssertTrue(advancedSource.contains("ForEach(PanelSection.allCases)"))
        XCTAssertTrue(advancedSource.contains("geekChartRangeTitle"))
        XCTAssertFalse(tertiaryDetailSource.contains("最近 120 秒"))
        XCTAssertFalse(tertiaryDetailSource.contains("Last 120 Seconds"))
        XCTAssertTrue(advancedSource.contains("GeekPrecisionLineChart"))
        XCTAssertTrue(advancedSource.contains("GeekPrecisionNetworkChart"))
        XCTAssertTrue(advancedSource.contains("GeekDiskIOChart"))
        XCTAssertTrue(advancedSource.contains("duration: geekChartDuration"))
        XCTAssertTrue(advancedSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(advancedSource.contains("grid(columns: 3"))
        XCTAssertTrue(advancedSource.contains("topProcesses"))
        XCTAssertTrue(systemModelSource.contains("enum PanelSection: String"))
        XCTAssertTrue(systemModelSource.contains("case overview"))
        XCTAssertTrue(systemModelSource.contains("case processor"))
        XCTAssertTrue(systemModelSource.contains("case memory"))
        XCTAssertTrue(systemModelSource.contains("case disk"))
        XCTAssertTrue(systemModelSource.contains("case network"))
        XCTAssertTrue(systemModelSource.contains("case sensors"))
        XCTAssertTrue(systemModelSource.contains("case power"))
        XCTAssertTrue(systemModelSource.contains("case cleanup"))
        XCTAssertTrue(auxiliaryMonitorSource.contains("BatteryPowerService.internalBatterySnapshot()"))
        XCTAssertTrue(auxiliaryMonitorSource.contains("NativeBatteryElectricalService.snapshot()"))
        XCTAssertTrue(auxiliaryMonitorSource.contains("NativeDiskIOMonitorService.counters()"))
        XCTAssertTrue(auxiliaryMonitorSource.contains("consumers: [UUID: MenuBarAuxiliaryMonitorDemand]"))
        XCTAssertTrue(advancedSource.contains("presentation.auxiliaryDemand("))
        XCTAssertTrue(advancedSource.contains(
            "geekConfiguration: panelSettingsState.geekDashboardConfiguration"
        ))
        XCTAssertTrue(advancedSource.contains(
            "let needsComplexOverviewTelemetry = self == .complex && section == .overview"
        ))
        XCTAssertTrue(advancedSource.contains("let visibleGeekModules = Set("))
        XCTAssertTrue(advancedSource.contains("let needsGeekOverviewDisk = self == .geek"))
        XCTAssertFalse(advancedSource.contains("let needsGeekOverviewNetwork = self == .geek"))
        XCTAssertTrue(advancedSource.contains("let needsGeekOverviewProcessor = self == .geek"))
        XCTAssertTrue(advancedSource.contains("|| needsGeekOverviewProcessor"))
        XCTAssertTrue(advancedSource.contains("|| needsGeekOverviewDisk"))
        XCTAssertFalse(advancedSource.contains("|| needsGeekOverviewNetwork"))
        XCTAssertTrue(advancedSource.contains(
            "store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)"
        ))
        XCTAssertFalse(advancedSource.contains("forceMemorySnapshot: true"))
        XCTAssertTrue(advancedSource.contains(
            ".onChange(of: panelSettingsState.geekDashboardConfiguration)"
        ))
        XCTAssertTrue(advancedSource.contains("monitorState.history"))
        XCTAssertFalse(advancedSource.contains("@State private var history: ["))
        XCTAssertTrue(telemetryModelSource.contains("static let duration: TimeInterval = 28 * 24 * 60 * 60"))
        XCTAssertTrue(telemetryModelSource.contains("static let highResolutionDuration: TimeInterval = 60 * 60"))
        XCTAssertTrue(telemetryModelSource.contains("static let bucketDuration: TimeInterval = 60"))
        XCTAssertTrue(telemetryModelSource.contains("static let maximumMinutePointCount = 28 * 24 * 60 + 1"))
        XCTAssertTrue(advancedSource.contains("MenuBarNetworkPalette.download"))
        XCTAssertTrue(advancedSource.contains("MenuBarNetworkPalette.upload"))
        XCTAssertTrue(advancedSource.contains("估算下载量"))
        XCTAssertTrue(advancedSource.contains("Estimated Download"))
        XCTAssertTrue(advancedSource.contains("估算上传量"))
        XCTAssertTrue(advancedSource.contains("Estimated Upload"))
        XCTAssertTrue(advancedSource.contains("估算下载"))
        XCTAssertTrue(advancedSource.contains("Est. Download"))
        XCTAssertTrue(advancedSource.contains("估算上传"))
        XCTAssertTrue(advancedSource.contains("Est. Upload"))
        XCTAssertTrue(advancedSource.contains("session total"))
        XCTAssertTrue(advancedSource.contains("ByteFormat.string(sessionDownloadedBytes)"))
        XCTAssertTrue(advancedSource.contains("ByteFormat.string(sessionUploadedBytes)"))
        XCTAssertTrue(advancedSource.contains("title: L10n.text(\"风扇转速\", \"Fan Speed\")"))
        XCTAssertTrue(advancedSource.contains("value: metricValue(.fanSpeed)"))
        XCTAssertTrue(advancedSource.contains("if metricAvailable(.fanSpeed)"))
        XCTAssertTrue(advancedSource.contains("valueRange: 20...110"))
        XCTAssertTrue(advancedSource.contains("title: L10n.text(\"平均转速\", \"Fan Average\")"))
        XCTAssertTrue(advancedSource.contains("geekSensorHeader(L10n.text(\"温度\", \"TEMPERATURE\"))"))
        XCTAssertTrue(advancedSource.contains("valueRange: 0...fanTrendMaximum"))
        XCTAssertTrue(advancedSource.contains("channel: .fanRPM"))
        XCTAssertFalse(advancedSource.contains("sensorTrendSeries"))
        XCTAssertFalse(advancedSource.contains("GeekMemoryCompositionHoverDetail"))
        XCTAssertTrue(advancedSource.contains("GPU、温度和风扇约每 2 秒更新"))
        XCTAssertTrue(advancedSource.contains(".monospacedDigit()"))
        XCTAssertFalse(advancedSource.contains("Timer.publish"))
        // MenuBarTelemetryChart.swift keeps only the shared series/sample/
        // geometry types after the unused legacy chart views were removed.
        XCTAssertTrue(telemetryChartSource.contains("static func pointSegments("))
        XCTAssertTrue(telemetryChartSource.contains("PanelChartSampling.samplingGapThreshold"))
        XCTAssertFalse(telemetryChartSource.contains(": View {"))
        XCTAssertTrue(chartSamplingSource.contains("static let minimumRenderableSampleCount = 2"))
        XCTAssertTrue(chartSamplingSource.contains("L10n.text(\"正在采样…\", \"Sampling…\")"))
        XCTAssertFalse(advancedSource.contains("EnergyImpactService.snapshot()"))
        XCTAssertFalse(advancedSource.contains("MemoryOptimizerService.snapshot()"))
        XCTAssertFalse(advancedSource.contains("Shell.capture"))
        let advancedAppIconSource = try XCTUnwrap(
            advancedSource.components(separatedBy: "struct AdvancedAppIcon: View").last
        )
        XCTAssertTrue(advancedAppIconSource.contains("CachedAppIconView("))
        XCTAssertFalse(advancedAppIconSource.contains("AppIconCache.icon(forFile:"))
        XCTAssertFalse(advancedAppIconSource.contains("FileManager.default.fileExists"))
    }

    func testAllPanelDensitiesShareOneRefreshActionDefinition() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsFolder = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views")
        let detailedSource = try String(
            contentsOf: viewsFolder
                .appendingPathComponent("MenuBarAdvanced")
                .appendingPathComponent("MenuBarAdvancedComponents.swift"),
            encoding: .utf8
        )
        let chromeSource = try String(
            contentsOf: viewsFolder.appendingPathComponent("MenuBarPanelChrome.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(detailedSource.contains("PanelHeader("))
        XCTAssertEqual(
            chromeSource.components(separatedBy: "立即刷新\", \"Refresh Now").count - 1,
            1,
            "Compact and detailed panels should share one localized refresh action definition."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: viewsFolder.appendingPathComponent("AdvancedMonitorWindowView.swift").path
        ))
    }

    func testCompactCleanupPanelAvoidsDuplicateOrMisleadingActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let groupRows = try XCTUnwrap(
            source.components(separatedBy: "private var cleanupGroupRows: some View").last?
                .components(separatedBy: "private var cleanupQuickActions: some View").first
        )
        let groupRowView = try XCTUnwrap(
            source.components(separatedBy: "private struct MenuBarCleanupGroupRow").last?
                .components(separatedBy: "private struct MenuBarUtilityActionRow").first
        )

        XCTAssertFalse(groupRows.contains("Button {"))
        XCTAssertFalse(groupRowView.contains("chevron.right"))
        XCTAssertTrue(source.contains("guard !store.isPreparingScan else { return false }"))
        XCTAssertTrue(source.contains("case .firstScan, .repairAccess, .rescan, .currentScan:"))
        XCTAssertTrue(source.contains("maintenanceRecommendation != .lowDisk"))
    }

    func testPanelControlsUseCompactMoreMenuAndImmediateSelection() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compactSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let advancedSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift"),
            encoding: .utf8
        )
        let chromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"),
            encoding: .utf8
        )

        for source in [compactSource, advancedSource] {
            XCTAssertFalse(source.contains("panelModeRawValue = mode.rawValue"))
            XCTAssertFalse(source.contains("private var currentPanelMode"))
            XCTAssertFalse(source.contains(".popover(isPresented: $isSettingsPresented"))
            XCTAssertTrue(source.contains("PanelShell("))
        }

        XCTAssertFalse(settingsSource.contains("struct PanelSettingsView: View"))
        XCTAssertFalse(settingsSource.contains("Form {"))
        XCTAssertFalse(settingsSource.contains("Menu {"))
        XCTAssertFalse(settingsSource.contains(".popover("))
        XCTAssertFalse(settingsSource.contains("@Environment(\\.dismiss)"))
        XCTAssertFalse(settingsSource.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertFalse(settingsSource.contains("xmark"))

        XCTAssertFalse(rootSource.contains("PanelSettingsView("))
        XCTAssertTrue(rootSource.contains("struct PanelScene: View"))
        XCTAssertFalse(rootSource.contains("Menu {"))
        XCTAssertFalse(rootSource.contains(".popover("))
        XCTAssertTrue(chromeSource.contains(".popover(isPresented: geekEditorBinding"))
        XCTAssertEqual(chromeSource.components(separatedBy: ".popover(isPresented:").count - 1, 1)
        XCTAssertFalse(chromeSource.contains("PanelSettingsView("))
        XCTAssertFalse(chromeSource.contains("if state.selectedDensity == .geek {"))
        XCTAssertTrue(chromeSource.contains("state.presentGeekEditor()"))
        XCTAssertEqual(
            chromeSource.components(separatedBy: "Customize Geek Overview…").count - 1,
            1
        )
        XCTAssertTrue(chromeSource.contains("GeekDashboardEditor(state: state)"))
        XCTAssertTrue(chromeSource.contains("启动时恢复小窗"))
        XCTAssertFalse(chromeSource.contains("isSettingsPresented"))
        XCTAssertFalse(chromeSource.contains("MenuBarStatusController.shared.selectPanelDensity(density)"))
        XCTAssertFalse(controllerSource.contains("PanelSettingsView("))
        XCTAssertFalse(controllerSource.contains("normalizedForMenuBar"))
        XCTAssertTrue(controllerSource.contains("UserDefaults.standard.set(density.rawValue, forKey: PanelDensity.defaultsKey)"))
        XCTAssertTrue(controllerSource.contains("panelSession?.selectDensity(density)"))
        XCTAssertFalse(controllerSource.contains("NSSize(width: 720, height: 620)"))
        XCTAssertFalse(settingsSource.contains("退出存储清理助手"))
        XCTAssertFalse(controllerSource.contains("panelModeChangeState"))
        XCTAssertFalse(controllerSource.contains("commitPendingPanelModeChange"))
    }

    @MainActor
    func testPanelDensitySelectionHasNoDeferredPendingState() {
        let state = MenuBarPanelSettingsState(initialDensity: .simple)
        state.selectDensity(.geek)

        XCTAssertEqual(state.selectedDensity, .geek)
    }

    func testMenuBarStatusIsPreparedBeforeOpeningPanel() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("store.prepareMenuBarLiveStatusOnLaunch()"))
        XCTAssertTrue(appSource.contains("computerHealthStore.prepareMenuBarHealthOnLaunch()"))
        XCTAssertTrue(storeSource.contains("func prepareMenuBarLiveStatusOnLaunch()"))
        XCTAssertTrue(storeSource.contains("refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)"))
        XCTAssertTrue(storeSource.contains("private lazy var menuBarRefreshCoordinator = MenuBarRefreshCoordinator { [weak self] request in"))
        XCTAssertFalse(storeSource.contains("isRefreshingMenuBarLiveStatus"))
    }

    func testNativeStatusItemUsesCompactMemoryStatus() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusRenderer.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"),
            encoding: .utf8
        )
        let compactSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("@StateObject private var menuBarStatusController = MenuBarStatusController.shared"))
        XCTAssertTrue(appSource.contains("menuBarStatusController.install("))
        XCTAssertTrue(appSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertFalse(appSource.contains("MenuBarExtra"))
        XCTAssertFalse(appSource.contains("systemImage: \"memorychip.fill\""))
        XCTAssertTrue(controllerSource.contains("NSStatusBar.system.statusItem(withLength: MenuBarStatusRenderer.initialWidth)"))
        XCTAssertTrue(rendererSource.contains("static let initialWidth: CGFloat = 54"))
        XCTAssertTrue(controllerSource.contains("private var panelSession: MenuBarPanelSession?"))
        XCTAssertTrue(controllerSource.contains("PanelScene("))
        XCTAssertTrue(controllerSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertTrue(controllerSource.contains("button.action = #selector(togglePanel(_:))"))
        XCTAssertTrue(controllerSource.contains("button.sendAction(on: [.leftMouseUp])"))
        XCTAssertTrue(controllerSource.contains("button.imagePosition = .imageOnly"))
        XCTAssertTrue(controllerSource.contains("button.title = \"\""))
        XCTAssertTrue(controllerSource.contains("func dismissPanel()"))
        XCTAssertTrue(compactSource.contains("MenuBarStatusController.shared.dismissPanel()"))
        XCTAssertTrue(rootSource.contains("struct PanelScene: View"))
        XCTAssertTrue(sessionSource.contains("panel.contentViewController = nil"))
        XCTAssertFalse(controllerSource.contains("NSPopover"))
        XCTAssertFalse(controllerSource.contains("NSPopoverDelegate"))
        XCTAssertTrue(controllerSource.contains("let image = MenuBarStatusRenderer.image"))
        XCTAssertTrue(controllerSource.contains("button.image = image"))
        XCTAssertTrue(controllerSource.contains("store.menuBarMonitorState.$snapshot"))
        XCTAssertFalse(controllerSource.contains("store.$menuBarMonitorSnapshot"))
        XCTAssertTrue(rendererSource.contains("statusSymbol(\"memorychip.fill\")"))
        XCTAssertTrue(rendererSource.contains("NSImage(systemSymbolName: name"))
        XCTAssertTrue(rendererSource.contains("throughput?.upBytesPerSecond"))
        XCTAssertTrue(rendererSource.contains("throughput?.downBytesPerSecond"))
        XCTAssertTrue(rendererSource.contains("let size = NSSize(width: initialWidth, height: height)"))
        XCTAssertTrue(rendererSource.contains("drawMemoryUsage(memoryUsageText(for: snapshot))"))
        XCTAssertTrue(rendererSource.contains("displayValue(for: .memoryUsage, snapshot: snapshot)"))
        XCTAssertTrue(rendererSource.contains("NSRect(x: 2, y: 5, width: 14, height: 14)"))
        XCTAssertTrue(rendererSource.contains("NSRect(x: 19, y: 5, width: 33, height: 14)"))
        XCTAssertTrue(rendererSource.contains("image.isTemplate = true"))
        XCTAssertTrue(rendererSource.contains("private static func shouldShow"))
        XCTAssertFalse(rendererSource.contains("drawMetric("))
        XCTAssertFalse(rendererSource.contains("drawNetwork("))
        XCTAssertFalse(rendererSource.contains("不可用"))
        XCTAssertFalse(controllerSource.contains("NSHostingController"))
        XCTAssertFalse(controllerSource.contains("NSHostingView<"))
    }

    func testSystemMonitorServiceUsesHIDSMCAndGPUDriverSensors() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/SystemMonitorService.swift"),
            encoding: .utf8
        )
        let smcSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/SMCFanSpeedService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("SMCFanSpeedService.currentHardwareReadings()"))
        XCTAssertTrue(source.contains("smcReadings.temperatureReadings"))
        XCTAssertTrue(source.contains("AppleSiliconTemperatureService.currentTemperatureReadings()"))
        XCTAssertTrue(source.contains("AppleSiliconTemperatureService.regionalTemperatures("))
        XCTAssertTrue(source.contains("GPUPerformanceService.currentSnapshot()"))
        XCTAssertTrue(source.contains("value: \"↓ --\""))
        XCTAssertTrue(source.contains("detail: \"↑ --\""))
        XCTAssertTrue(source.contains("实时芯片最高温"))
        XCTAssertTrue(source.contains("fanSpeedDetail(fanCount:"))
        XCTAssertTrue(source.contains("host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO"))
        XCTAssertTrue(source.contains("getifaddrs(&firstAddress)"))
        XCTAssertTrue(source.contains("private static let gpuSamplingInterval: TimeInterval = 1"))
        XCTAssertTrue(source.contains("static let background: TimeInterval = 15"))
        XCTAssertTrue(source.contains("static let interactive: TimeInterval = 2"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(gpuSampledAt) < Self.gpuSamplingInterval"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(thermalSampledAt) < max(1, samplingInterval)"))
        XCTAssertTrue(source.contains("SystemMonitorService.temperatureAndFanReadings()"))
        XCTAssertTrue(source.contains("private var isGPUSampleInFlight = false"))
        XCTAssertTrue(source.contains("private var isThermalSampleInFlight = false"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("finishThermalSample("))
        XCTAssertTrue(source.contains("generation: generation"))
        XCTAssertTrue(source.contains("guard generation == thermalSampleGeneration"))
        XCTAssertEqual(smcSource.components(separatedBy: "output.result == 0").count - 1, 2)
        XCTAssertTrue(smcSource.contains("(0...20_000).contains(speed)"))
        XCTAssertFalse(source.contains("Shell.capture(\"/bin/ps\""))
        XCTAssertFalse(source.contains("Shell.capture(\"/usr/sbin/netstat\""))
        XCTAssertFalse(source.contains("chipTemperatureCelsius: SMCFanSpeedService.currentChipTemperatureCelsius()"))
        XCTAssertFalse(source.contains("Shell.capture(\n                \"/usr/bin/powermetrics\""))
        XCTAssertFalse(source.contains("\"smc,gpu_power\""))
    }

    private func telemetryPoint(
        date: Date,
        cpuTotal: Double? = nil,
        downBytesPerSecond: Int64? = nil,
        upBytesPerSecond: Int64? = nil
    ) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date,
            cpuTotal: cpuTotal,
            cpuUser: nil,
            cpuSystem: nil,
            gpu: nil,
            memory: nil,
            chipTemperature: nil,
            fanRPM: nil,
            downBytesPerSecond: downBytesPerSecond,
            upBytesPerSecond: upBytesPerSecond
        )
    }

    private func memoryHistorySnapshot(
        at date: Date,
        usedPercent: Double?,
        pressureFreePercent: Int?,
        compressedBytes: UInt64?,
        swapUsedBytes: UInt64?
    ) -> MemorySnapshot {
        let physicalBytes: UInt64 = 1_000
        let availableBytes = usedPercent.map {
            UInt64((Double(physicalBytes) * (1 - $0 / 100)).rounded())
        }
        func measurement(
            _ value: UInt64?
        ) -> MemoryMeasurement<UInt64> {
            value.map(MemoryMeasurement.available)
                ?? .unavailable(.temporarilyInvalid, reason: "Missing fixture value")
        }
        let measurements = MemoryMeasurements(
            pressure: pressureFreePercent.map { _ in
                MemoryMeasurement.available(.normal)
            } ?? .unavailable(.temporarilyInvalid, reason: "Missing fixture value"),
            physicalBytes: .available(physicalBytes),
            availableBytes: measurement(availableBytes),
            appBytes: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            wiredBytes: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            compressedBytes: measurement(compressedBytes),
            cachedBytes: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            swapUsedBytes: measurement(swapUsedBytes),
            swapInRate: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            swapOutRate: .unavailable(.temporarilyInvalid, reason: "Not needed")
        )
        return MemorySnapshot(
            generatedAt: date,
            physicalBytes: Int64(physicalBytes),
            freeBytes: Int64(availableBytes ?? 0),
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: 0,
            compressedBytes: Int64(compressedBytes ?? 0),
            swapUsedBytes: Int64(swapUsedBytes ?? 0),
            pressureFreePercentage: pressureFreePercent,
            pressureSummary: "Fixture",
            topProcesses: [],
            measurements: measurements
        )
    }

    private func advancedPanelSource(projectRoot: URL) throws -> String {
        let viewsFolder = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views")
        let rootURL = viewsFolder.appendingPathComponent("MenuBarAdvancedStatusView.swift")
        let sectionFolder = viewsFolder.appendingPathComponent("MenuBarAdvanced")
        let sectionURLs = try FileManager.default
            .contentsOfDirectory(at: sectionFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try ([rootURL] + sectionURLs)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    func testNativeDiskIOThroughputUsesMonotonicIOKitCounters() throws {
        let start = Date(timeIntervalSince1970: 100)
        let previous = NativeDiskIOCounters(
            date: start,
            readBytes: 1_000,
            writtenBytes: 2_000,
            readOperations: 20,
            writeOperations: 30,
            driverCount: 2
        )
        let current = NativeDiskIOCounters(
            date: start.addingTimeInterval(2),
            readBytes: 5_000,
            writtenBytes: 8_000,
            readOperations: 30,
            writeOperations: 46,
            driverCount: 2
        )

        let point = try XCTUnwrap(
            NativeDiskIOMonitorService.throughput(current: current, previous: previous)
        )
        XCTAssertEqual(point.readBytesPerSecond, 2_000)
        XCTAssertEqual(point.writeBytesPerSecond, 3_000)
        XCTAssertEqual(point.readOperationsPerSecond, 5, accuracy: 0.001)
        XCTAssertEqual(point.writeOperationsPerSecond, 8, accuracy: 0.001)

        let attachedDrive = NativeDiskIOCounters(
            date: start.addingTimeInterval(3),
            readBytes: 9_000,
            writtenBytes: 14_000,
            readOperations: 40,
            writeOperations: 60,
            driverCount: 3
        )
        XCTAssertNil(NativeDiskIOMonitorService.throughput(current: attachedDrive, previous: current))

        let reset = NativeDiskIOCounters(
            date: start.addingTimeInterval(3),
            readBytes: 10,
            writtenBytes: 10,
            readOperations: 1,
            writeOperations: 1,
            driverCount: 1
        )
        XCTAssertNil(NativeDiskIOMonitorService.throughput(current: reset, previous: current))
    }

    func testNativeBatteryElectricalSnapshotNormalizesAllowlistedIOKitFields() throws {
        let snapshot = try XCTUnwrap(
            NativeBatteryElectricalService.snapshot(
                properties: [
                    "BatteryData": [
                        "Voltage": 13_175,
                        "Amperage": -1_250,
                        "Temperature": 3_519,
                        "DesignCapacity": 6_000,
                        "AppleRawCurrentCapacity": 4_100,
                        "AppleRawMaxCapacity": 5_200,
                        "CycleCount": 321,
                        "BatteryHealth": "Good",
                        "Serial": "must-not-be-read"
                    ]
                ],
                now: Date(timeIntervalSince1970: 42)
            )
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.voltageVolts), 13.175, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.amperageAmps), -1.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.powerWatts), -16.46875, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.temperatureCelsius), 35.19, accuracy: 0.0001)
        XCTAssertEqual(snapshot.designCapacityMAh, 6_000)
        XCTAssertEqual(snapshot.currentCapacityMAh, 4_100)
        XCTAssertEqual(snapshot.maximumCapacityMAh, 5_200)
        XCTAssertEqual(snapshot.cycleCount, 321)
        XCTAssertEqual(snapshot.condition, .normal)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 42))
    }

    func testNativeBatteryElectricalSnapshotSupportsAdapterOnlyMacs() throws {
        let snapshot = try XCTUnwrap(
            NativeBatteryElectricalService.snapshot(
                properties: [:],
                adapterProperties: [
                    "Watts": 60,
                    "AdapterVoltage": 20_000,
                    "Current": 3_000,
                    "Description": "pd charger",
                ],
                now: Date(timeIntervalSince1970: 84)
            )
        )

        XCTAssertFalse(snapshot.hasBatteryData)
        XCTAssertTrue(snapshot.hasAdapterData)
        XCTAssertEqual(try XCTUnwrap(snapshot.adapterPowerWatts), 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.adapterVoltageVolts), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.adapterAmperageAmps), 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.adapterName, "pd charger")
        XCTAssertNil(snapshot.voltageVolts)
        XCTAssertNil(snapshot.amperageAmps)
    }

    func testHIDTemperatureClientIsReusedSerializedAndRetryable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppleSiliconTemperatureService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private static let clientStore = TemperatureClientStore()"))
        XCTAssertTrue(source.contains("private final class TemperatureClientStore: @unchecked Sendable"))
        XCTAssertTrue(source.contains("private final class TemperatureClient: @unchecked Sendable"))
        XCTAssertTrue(source.contains("private let lock = NSLock()"))
        XCTAssertTrue(source.contains("clientStore.readings()"))
        XCTAssertTrue(source.contains("retryInterval: TimeInterval = 30"))
        XCTAssertTrue(source.contains("consecutiveEmptyReadings >= 3"))
        XCTAssertTrue(source.contains("invalidate(currentClient, now: now)"))
        XCTAssertEqual(source.components(separatedBy: "symbols.create(kCFAllocatorDefault)").count - 1, 1)
    }

    func testMacOS26UsesFixedScrollSidebarAndCompactPanelControls() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let sidebarSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SidebarView.swift"),
            encoding: .utf8
        )
        let glassSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/GlassStyle.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"),
            encoding: .utf8
        )
        let compactPanelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )
        let advancedPanelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"),
            encoding: .utf8
        )
        let advancedStatusSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift"),
            encoding: .utf8
        )
        let chromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(packageSource.contains(".macOS(.v14)"))
        XCTAssertTrue(sidebarSource.contains("ScrollView(.vertical)"))
        XCTAssertTrue(sidebarSource.contains("ForEach(SidebarGroup.allCases)"))
        XCTAssertFalse(sidebarSource.contains(".scrollIndicators(.hidden)"))
        XCTAssertTrue(sidebarSource.contains("LinearGradient("))
        XCTAssertFalse(sidebarSource.contains(".environment(\\.colorScheme, .dark)"),
                       "The sidebar must inherit the selected day/night appearance")
        XCTAssertTrue(sidebarSource.contains("AppAppearanceColors.sidebarTop"))
        XCTAssertTrue(sidebarSource.contains("accent.opacity(colorScheme == .dark ? 0.30 : 0.12)"))
        XCTAssertFalse(sidebarSource.contains("List(selection: listSelection)"))
        XCTAssertFalse(sidebarSource.contains("legacyBackdrop"))
        XCTAssertFalse(glassSource.contains(".glassEffect("))
        XCTAssertTrue(glassSource.contains("private struct GlassSurfaceDepthKey"))
        XCTAssertTrue(glassSource.contains("@Environment(\\.glassSurfaceDepth)"))
        XCTAssertTrue(glassSource.contains("private struct AdaptivePopoverChromeModifier"))
        XCTAssertTrue(glassSource.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertTrue(glassSource.contains(".fill(AppDesignTokens.Palette.contentBackground)"))
        XCTAssertTrue(glassSource.contains(".strokeBorder(borderColor, lineWidth: borderWidth)"))
        XCTAssertTrue(glassSource.contains("view.state = .followsWindowActiveState"))
        XCTAssertFalse(glassSource.contains("GlassVisualEffectBackdrop(material: .popover"))
        XCTAssertFalse(glassSource.contains("GlassVisualEffectBackdrop(material: .underWindowBackground"))
        XCTAssertFalse(glassSource.contains("tinted.interactive()"))
        XCTAssertFalse(glassSource.contains("struct MenuBarGlassBackdrop"))
        XCTAssertFalse(glassSource.contains("RadialGradient("))
        XCTAssertTrue(compactPanelSource.contains("PanelShell(density: .simple"))
        XCTAssertFalse(compactPanelSource.contains("MenuBarGlassBackdrop"))
        XCTAssertFalse(compactPanelSource.contains("colorScheme == .dark ? 0.46 : 0.60"))
        XCTAssertTrue(advancedStatusSource.contains("density: presentation"))
        XCTAssertFalse(advancedStatusSource.contains("AdvancedPanelBackdrop()"))
        XCTAssertFalse(advancedPanelSource.contains("MenuBarGlassBackdrop"))
        XCTAssertFalse(advancedPanelSource.contains("colorScheme == .dark ? 0.44 : 0.58"))
        XCTAssertTrue(chromeSource.contains(".metricPanelShell()"))
        XCTAssertFalse(chromeSource.contains("Color(nsColor: .windowBackgroundColor)"),
                       "Panel content must not cover the shared shell background")
        XCTAssertFalse(chromeSource.contains("Color.gray"))
        XCTAssertFalse(settingsSource.contains(".glassPanel("))
        XCTAssertFalse(settingsSource.contains(".background(.regularMaterial"))
        XCTAssertFalse(rootSource.contains(".controlSize(.small)"))
        XCTAssertTrue(sessionSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(sessionSource.contains("prefersCompactControlSizeMetrics = true"))
        XCTAssertFalse(controllerSource.contains("prefersCompactControlSizeMetrics"))
    }

    func testMenuBarLiveStatusThrottlesMemorySnapshotAndRefreshesMetrics() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("func refreshMenuBarLiveStatus(showLoadingWhenEmpty: Bool = false, forceMemorySnapshot: Bool = false)"))
        XCTAssertTrue(source.contains("shouldRefreshMenuBarMemorySnapshot"))
        XCTAssertTrue(source.contains("menuBarRefreshInterval.memorySnapshotSeconds"))
        XCTAssertTrue(source.contains("currentMemorySnapshot"))
        XCTAssertTrue(source.contains("MemoryOptimizerService.snapshot()"))
        XCTAssertTrue(source.contains("MemoryOptimizerService.statusSnapshot()"))
        XCTAssertTrue(source.contains("menuBarMemoryStatusSnapshot"))
        XCTAssertTrue(source.contains("let menuBarMonitorState: MenuBarMonitorState"))
        XCTAssertTrue(source.contains("menuBarMonitorState = MenuBarMonitorState(\n            metricHistoryStore: metricHistoryStore"))
        XCTAssertTrue(source.contains(
            "menuBarMonitorState.recordMemorySample(snapshot)"
        ))
        XCTAssertFalse(source.contains("@Published var menuBarMonitorSnapshot"))
        XCTAssertTrue(source.contains("final class MenuBarRefreshCoordinator"))
        XCTAssertTrue(source.contains("private var pendingRequest: MenuBarRefreshRequest?"))
        XCTAssertTrue(source.contains("pendingRequest.merging(request)"))
        XCTAssertTrue(source.contains("menuBarRefreshCoordinator.request("))
        XCTAssertTrue(source.contains("driverTask = Task { @MainActor [weak self] in"))
        XCTAssertTrue(source.contains("requestMenuBarRefresh(policy: .lightweight)"))
        XCTAssertTrue(source.contains("forceMemorySnapshot ? .fullMemory : .automatic"))
        let requestSource = try XCTUnwrap(
            source.components(separatedBy: "    private func requestMenuBarRefresh(").dropFirst().first?
                .components(separatedBy: "    private func performMenuBarRefresh(").first
        )
        XCTAssertTrue(requestSource.contains("menuBarRefreshCoordinator.request("))
        XCTAssertFalse(requestSource.contains("Task {"))
        XCTAssertFalse(source.contains("isMenuBarFullMemoryRefreshPending"))
        XCTAssertFalse(source.contains("isMenuBarMonitorRefreshPending"))
        XCTAssertFalse(source.contains("finishMenuBarLiveRefresh"))
        XCTAssertTrue(source.contains("memorySnapshot: snapshot"))
        XCTAssertTrue(source.contains("memorySnapshot = snapshot"))
        XCTAssertTrue(source.contains("markMenuBarMemorySnapshotRefreshed(at: snapshot.generatedAt)"))
        XCTAssertTrue(source.contains("pruneMemoryProcessSelection(using: snapshot)"))
        XCTAssertTrue(source.contains("!isLoadingMemory"))
        XCTAssertTrue(source.contains("!isOptimizingMemory"))
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
