import Foundation
import XCTest
@testable import StorageCleanerMac

/// BOARD N16-5 and N16-6 (live 2026-10-07, on external power):
/// - the energy page showed "0.000 kWh", "覆盖 0%", "已记录 0 秒" next to a
///   62-hour uptime and per-app Wh. Cause: the session only integrates
///   measured battery samples (on battery) or attributed estimates taken
///   while the power page samples processes; on external power nothing ran
///   in the background, and the energy page's own scan marks a gap before
///   its sample, so it never integrates. The card showed that empty session
///   as a measured zero "since boot".
/// - the power page's "整机 · 电池侧" and "CPU / 显示器" showed "—" on external
///   power.
/// On external power the battery controller reports the whole computer's
/// load (PowerTelemetryData.SystemLoad, mW); it is now read (cross-checked
/// against the block's own input reading) and integrated in the background
/// like battery samples. An empty session shows "—" and why; rows with no
/// reading are not shown.
@MainActor
final class SystemEnergyACTelemetryTests: XCTestCase {
    /// The block on the M5 Pro where this was found (external power, full).
    private let telemetry: [String: Any] = [
        "SystemLoad": 40_035, "SystemPowerIn": 40_035,
        "SystemVoltageIn": 19_813, "SystemCurrentIn": 2_020,
        "AdapterEfficiencyLoss": 1_079,
    ]

    func testTheSystemLoadIsReadOnExternalPowerAndCrossChecked() {
        let watts = NativeBatteryElectricalService.systemLoadWatts(telemetry: telemetry, externalConnected: true)
        XCTAssertEqual(watts ?? 0, 40.035, accuracy: 0.000_1)

        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(telemetry: telemetry, externalConnected: false),
                     "on battery the battery side is measured instead")
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(telemetry: telemetry, externalConnected: nil))
        var inconsistent = telemetry
        inconsistent["SystemCurrentIn"] = 4_000
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(telemetry: inconsistent, externalConnected: true),
                     "voltage × current must match the reported input")
        for key in ["SystemLoad", "SystemPowerIn", "SystemVoltageIn", "SystemCurrentIn"] {
            var missing = telemetry
            missing[key] = nil
            XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(telemetry: missing, externalConnected: true), key)
        }
        var idle = telemetry
        idle["SystemLoad"] = 0
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(telemetry: idle, externalConnected: true))

        let snapshot = NativeBatteryElectricalService.snapshot(properties: [
            "ExternalConnected": true, "Voltage": 12_955, "Amperage": 0, "PowerTelemetryData": telemetry,
        ])
        XCTAssertEqual(snapshot?.systemLoadWatts ?? 0, 40.035, accuracy: 0.000_1)
    }

    /// r2-live-fixes-2 review P2-5: the load must be supplied by the input
    /// plus what the battery gives (it can discharge on external power when
    /// the adapter is too small), within max(1 W, 10%). A self-consistent
    /// input of 20 W cannot carry a 900 W load.
    func testTheLoadMustBeSuppliedByTheInputAndTheBattery() {
        let impossible: [String: Any] = [
            "SystemLoad": 900_000, "SystemPowerIn": 20_000,
            "SystemVoltageIn": 20_000, "SystemCurrentIn": 1_000,
        ]
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: impossible, externalConnected: true, batteryPowerWatts: 0))
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: impossible, externalConnected: true, batteryPowerWatts: nil))

        // 85 W from a 60 W input: only with the battery giving about 25 W.
        let heavy: [String: Any] = [
            "SystemLoad": 85_000, "SystemPowerIn": 60_000,
            "SystemVoltageIn": 20_000, "SystemCurrentIn": 3_000,
        ]
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: heavy, externalConnected: true, batteryPowerWatts: 1.5), "a charging battery adds nothing")
        XCTAssertNil(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: heavy, externalConnected: true, batteryPowerWatts: nil), "an unknown battery adds nothing")
        XCTAssertEqual(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: heavy, externalConnected: true, batteryPowerWatts: -25) ?? 0, 85, accuracy: 0.001)

        // The block the M5 Pro reported (load = input) is still read.
        XCTAssertEqual(NativeBatteryElectricalService.systemLoadWatts(
            telemetry: telemetry, externalConnected: true, batteryPowerWatts: 0) ?? 0, 40.035, accuracy: 0.000_1)
    }

    func testOnExternalPowerTheMeasuredLoadAccumulatesInTheBackground() throws {
        let accumulator = SystemEnergyAccumulator(fileURL: nil, samplingGaps: MenuBarSamplingGaps(defaults: TestPreferenceDomain.make(for: self)), sampleProvider: { nil })
        accumulator.recordBattery(ac, electrical: electrical(load: 40), uptime: 1_000)
        accumulator.recordBattery(ac, electrical: electrical(load: 40), uptime: 1_060)

        XCTAssertEqual(accumulator.snapshot.acWattHours, 40.0 * 60 / 3_600, accuracy: 0.000_1)
        XCTAssertEqual(accumulator.snapshot.measuredSeconds, 60)
        XCTAssertEqual(accumulator.snapshot.lastSample?.source, SystemEnergyPowerSample.systemLoadSource)
        XCTAssertEqual(accumulator.snapshot.lastSample?.confidence, .measured)

        // Without a reading on external power nothing is recorded, nothing
        // is broken off.
        accumulator.recordBattery(ac, electrical: electrical(load: nil), uptime: 1_090)
        accumulator.recordBattery(ac, electrical: electrical(load: 40), uptime: 1_120)
        XCTAssertEqual(accumulator.snapshot.measuredSeconds, 120)
    }

    /// The energy page's scan and the power page's sampler estimate from the
    /// attributed processes; with a measured load they neither replace it nor
    /// break the session off.
    func testAttributedEstimatesDoNotInterruptTheMeasuredLoad() throws {
        let accumulator = SystemEnergyAccumulator(fileURL: nil, samplingGaps: MenuBarSamplingGaps(defaults: TestPreferenceDomain.make(for: self)), sampleProvider: { nil })
        accumulator.recordBattery(ac, electrical: electrical(load: 40), uptime: 1_000)
        accumulator.recordAttributed(attributedReading(watts: 9), powerSource: .acPower, continuous: false, uptime: 1_040)
        accumulator.recordBattery(ac, electrical: electrical(load: 40), uptime: 1_060)
        XCTAssertEqual(accumulator.snapshot.measuredSeconds, 60, "the scan did not mark a gap")
        XCTAssertEqual(accumulator.snapshot.estimatedSeconds, 0)
        XCTAssertEqual(accumulator.snapshot.acWattHours, 40.0 * 60 / 3_600, accuracy: 0.000_1)
    }

    func testAnEmptySessionIsNotShownAsAMeasuredZero() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        defer { chinese.restore() }
        let boot = SystemEnergyBootIdentity(identifier: "boot", startedAt: Date(timeIntervalSince1970: 0), uptimeSeconds: 0)
        let empty = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: Date(timeIntervalSince1970: 3_600))
        XCTAssertFalse(empty.hasRecordedEnergy)
        XCTAssertEqual(empty.recordedEnergyText, "—")
        XCTAssertTrue(empty.recordedEnergyDetail.contains("尚未记录"), empty.recordedEnergyDetail)
        XCTAssertEqual(empty.energyTitle(uptimeSeconds: 62 * 3_600), "监测期间耗电")

        var monitored = empty
        monitored.append(sample(at: 0, watts: 40, source: .ac, confidence: .measured))
        monitored.append(sample(at: 60, watts: 40, source: .ac, confidence: .measured))
        XCTAssertTrue(monitored.hasRecordedEnergy)
        XCTAssertEqual(monitored.recordedEnergyText, "0.001 kWh")
        XCTAssertEqual(monitored.energyTitle(uptimeSeconds: 62 * 3_600), "监测期间耗电",
                       "one minute of a 62-hour boot is not energy since boot")
        XCTAssertEqual(monitored.currentPowerDetail(now: Date(timeIntervalSince1970: 3_660)), "整机负载实测（外接电源）")

        // Monitored from boot, measured throughout.
        var full = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: Date(timeIntervalSince1970: 1))
        full.append(sample(at: 0, watts: 40, source: .battery, confidence: .measured))
        full.append(sample(at: 60, watts: 40, source: .battery, confidence: .measured))
        XCTAssertEqual(full.energyTitle(uptimeSeconds: 60), "本次开机耗电")
        XCTAssertEqual(full.currentPowerDetail(now: Date(timeIntervalSince1970: 3_660)), "电池功率实测（SMC，约每秒更新）")

        // D57 supplement: the battery controller's V x I and a session saved
        // before D57 keep their own label; SMC V x I on a Mac without B0AP
        // (incremental review P2-2) has its own.
        for (source, detail) in [
            (SystemEnergyPowerSample.batteryControllerSource, "电池电压与电流实测"),
            (SystemEnergyPowerSample.legacyBatterySource, "电池电压与电流实测"),
            (SystemEnergyPowerSample.batterySMCVoltageCurrentSource, "电池电压 × 电流实测（SMC，约每秒更新）"),
            (SystemEnergyPowerSample.batterySMCSource, "电池功率实测（SMC，约每秒更新）"),
        ] {
            var labelled = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: Date(timeIntervalSince1970: 1))
            labelled.append(SystemEnergyPowerSample(
                monotonicSeconds: 0, wallClock: Date(timeIntervalSince1970: 3_600), watts: 40,
                powerSource: .battery, confidence: .measured, source: source
            ))
            XCTAssertEqual(labelled.currentPowerDetail(now: Date(timeIntervalSince1970: 3_660)), detail, source)
        }
        XCTAssertEqual(SystemEnergyPowerSample.batterySMCVoltageCurrentSource, "smc-battery-voltage-current")
    }

    /// r2-live-fixes-2 review P2-6: the energy page's "当前功率" card says
    /// there is no reading when there is none (it said "应用进程归属估算"
    /// beside "—"), and a reading older than 90 s is not shown as current
    /// (a stopped system-load reading stayed "整机负载实测" indefinitely): the
    /// value is hidden and the detail gives the reading's time.
    func testTheCurrentPowerCardShowsOnlyARecentReading() throws {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        defer { chinese.restore() }
        let boot = SystemEnergyBootIdentity(identifier: "boot", startedAt: Date(timeIntervalSince1970: 0), uptimeSeconds: 0)
        let empty = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(empty.currentPowerText(now: Date(timeIntervalSince1970: 3_700)), "—")
        XCTAssertEqual(empty.currentPowerDetail(now: Date(timeIntervalSince1970: 3_700)), "暂无当前读数")

        var session = empty
        session.append(sample(at: 0, watts: 40, source: .ac, confidence: .measured))
        XCTAssertEqual(SystemEnergySessionSnapshot.currentPowerMaximumAge, 90)
        let recent = Date(timeIntervalSince1970: 3_600 + 89)
        XCTAssertEqual(session.currentPowerText(now: recent), EnergyImpactApp.powerText(40))
        XCTAssertEqual(session.currentPowerDetail(now: recent), "整机负载实测（外接电源）")

        let late = Date(timeIntervalSince1970: 3_600 + 91)
        XCTAssertEqual(session.currentPowerText(now: late), "—", "an old reading is not current")
        let detail = session.currentPowerDetail(now: late)
        XCTAssertTrue(detail.hasPrefix("暂无当前读数"), detail)
        XCTAssertTrue(detail.contains(PanelTimestampFormat.display(Date(timeIntervalSince1970: 3_600))), detail)

        // The card reads them at the time it is drawn, redrawn while shown.
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let card = try MiniWindowLogicFixtures.section(
            view, from: "title: L10n.text(\"当前功率\", \"Current Power\")", to: "title: L10n.text(\"监测覆盖率\"")
        XCTAssertTrue(card.contains("systemEnergy?.currentPowerText(now: context.date)"))
        XCTAssertTrue(card.contains("systemEnergy?.currentPowerDetail(now: context.date)"))
        let grid = try MiniWindowLogicFixtures.section(
            view, from: "private struct EnergyImpactSummaryGrid: View {", to: "title: L10n.text(\"监测覆盖率\"")
        XCTAssertTrue(grid.contains("TimelineView(.periodic(from: .now, by: 15)) { context in"))
    }

    /// D57 replaced N16-6's rows: the whole computer is SMC `PSTR` (once a
    /// second) instead of the battery controller's once-a-minute SystemLoad
    /// or the battery side, and the battery row is `PPBR`. Rows without a
    /// key are still not shown (MiniSensorsNoValueRuleTests covers M1–M5).
    func testThePowerRowsShowOnlyWhatIsMeasured() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        defer { chinese.restore() }
        let now = Date()
        func telemetry(_ keys: [String: MiniSensorsDecodingTests.SMCFixture.Entry]) -> MenuBarPowerTelemetry {
            MenuBarPowerTelemetry(
                smc: SMCPowerTelemetryService.telemetry(
                    read: MiniSensorsDecodingTests.SMCFixture(keys: keys).read, platform: .appleSilicon
                ),
                backlightBrightnessNits: .unsupported, soc: .unsupported, generatedAt: now
            )
        }
        let onAC = GeekPowerReadouts.rows(hasInternalBattery: true, powerSource: .acPower,
                                          telemetry: telemetry(MiniSensorsDecodingTests.mac17_9.keys),
                                          electrical: electrical(load: 40.04, batteryWatts: 0), now: now)
        XCTAssertEqual(onAC.map(\.title), ["整机", "电源输入", "电池", "屏幕背光"])
        // D128 (2026-10-19): iStat's power format (was "87.90 W").
        XCTAssertEqual(onAC.first?.value, "87.9 W", "PSTR, not the 60 s SystemLoad (40.04 W)")
        XCTAssertFalse(onAC.contains { $0.value == "—" }, "no row without a value")

        let systemOnly = GeekPowerReadouts.rows(hasInternalBattery: true, powerSource: .acPower,
                                                telemetry: telemetry(["PSTR": .init("flt ", "9eceaf42")]),
                                                electrical: electrical(load: 40.04, batteryWatts: 0), now: now)
        XCTAssertEqual(systemOnly.map(\.title), ["整机"], "missing keys: hidden rows")

        let onBattery = GeekPowerReadouts.rows(hasInternalBattery: true, powerSource: .batteryPower,
                                               telemetry: telemetry(MiniSensorsDecodingTests.mac17_9.keys),
                                               electrical: electrical(load: nil, batteryWatts: -12.5), now: now)
        XCTAssertEqual(onBattery.map(\.title), ["整机", "电池", "屏幕背光"])

        XCTAssertTrue(GeekPowerReadouts.rows(hasInternalBattery: false, powerSource: nil, telemetry: nil, electrical: nil).isEmpty,
                      "nothing sampled yet: no rows, the card is not shown")
    }

    /// The real reading on this Mac, read-only (skipped without a battery
    /// controller or on battery).
    func testTheLocalSystemLoadOnExternalPower() throws {
        guard BatteryPowerService.currentSystemPowerSource() == .acPower,
              let snapshot = NativeBatteryElectricalService.snapshot(), snapshot.hasBatteryData else {
            throw XCTSkip("no internal battery on external power here")
        }
        let watts = try XCTUnwrap(snapshot.systemLoadWatts, "the battery controller reports the system load")
        print("System load on external power on this Mac: \(String(format: "%.2f", watts)) W")
        XCTAssertTrue((0.5...500).contains(watts))
    }

    // MARK: - Support

    private let ac = BatteryPowerSnapshot(chargePercent: 100, isCharging: false, powerSource: .acPower,
                                          timeToEmptyMinutes: nil, timeToFullChargeMinutes: nil)

    private func electrical(load: Double?, batteryWatts: Double? = 0) -> NativeBatteryElectricalSnapshot {
        NativeBatteryElectricalSnapshot(
            generatedAt: Date(), voltageVolts: 12.955, amperageAmps: batteryWatts.map { $0 / 12.955 },
            powerWatts: batteryWatts, temperatureCelsius: nil, adapterPowerWatts: 60, adapterVoltageVolts: 20,
            adapterAmperageAmps: 3, adapterName: nil, designCapacityMAh: nil, currentCapacityMAh: nil,
            maximumCapacityMAh: nil, cycleCount: nil, condition: nil, systemLoadWatts: load)
    }

    private func attributedReading(watts: Double) -> EnergyImpactSnapshot {
        let app = EnergyImpactApp(
            id: "/Applications/Fixture.app", name: "Fixture", path: "/Applications/Fixture.app",
            iconPath: "", bundlePath: "/Applications/Fixture.app", bundleIdentifier: nil,
            measuredEnergyWh: 0, estimatedSupplementEnergyWh: 0, estimatedEnergyWh: 0,
            currentPowerWatts: watts, averagePowerWatts: watts, cpuPercent: 10,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, residentBytes: 0,
            cumulativeCPUSeconds: 1, longestRunningSeconds: 10, processCount: 1, measuredProcessCount: 1,
            processIDs: [1], isApplication: true)
        return EnergyImpactSnapshot(
            generatedAt: Date(), scanSeconds: 1, sampleSeconds: 1, uptimeSeconds: 100, apps: [app],
            processCount: 1, measuredProcessCount: 1, unmeasuredProcessCount: 0, measuredTotalEnergyWh: 0,
            estimatedSupplementEnergyWh: 0, calibrationWattsPerCore: 1, usesLocalCalibration: false)
    }

    private func sample(at seconds: TimeInterval, watts: Double, source: SystemEnergyPowerSource,
                        confidence: SystemEnergySampleConfidence) -> SystemEnergyPowerSample {
        SystemEnergyPowerSample(
            monotonicSeconds: seconds, wallClock: Date(timeIntervalSince1970: 3_600 + seconds), watts: watts,
            powerSource: source, confidence: confidence,
            source: source == .battery ? SystemEnergyPowerSample.batterySMCSource : SystemEnergyPowerSample.systemLoadSource)
    }
}
