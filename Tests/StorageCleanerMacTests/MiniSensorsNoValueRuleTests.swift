import Foundation
import XCTest
@testable import StorageCleanerMac

/// DECISIONS D57 ④ across M1–M5 key sets: a key or channel that does not
/// exist hides its row (the third level says "本机不支持"), an out-of-range
/// value shows "—" (third level "读数无效"), and a legal zero is shown.
@MainActor
final class MiniSensorsNoValueRuleTests: XCTestCase {
    private var language: MiniWindowLogicLanguageScope?

    override func setUp() async throws {
        language = MiniWindowLogicLanguageScope(.zhHans)
    }

    override func tearDown() async throws {
        language?.restore()
        language = nil
    }

    // MARK: - Power card rows per machine

    func testM5ProLaptopOnExternalPowerShowsEveryRow() throws {
        let rows = rows(profile: .m5Pro, powerSource: .acPower)
        XCTAssertEqual(rows.map(\.title), ["整机", "电源输入", "电池", "屏幕背光", "芯片合计"])
        XCTAssertFalse(rows.contains { $0.value == "—" })
        // D128 (2026-10-19): unsigned power in iStat's sensor format, at most
        // one decimal (was "87.90 W", "63.36 W", "4.67 W", "18.80 W"); the
        // signed battery row keeps our direction format.
        XCTAssertEqual(rows[0].value, "87.9 W")
        XCTAssertEqual(rows[1].value, "63.4 W")
        XCTAssertEqual(rows[2].value, "-10.75 W", "B0AP, negative because B0AC flows out of the battery")
        XCTAssertEqual(rows[3].value, "4.7 W")
        XCTAssertEqual(rows[4].value, "18.8 W")
        let battery = try XCTUnwrap(rows.first { $0.id == "power-battery" })
        XCTAssertEqual(battery.source, "SMC B0AP")
        XCTAssertEqual(battery.detailRows.map(\.title), ["方向", "电池轨（SMC）"])
        // D128: was "11.43 W".
        XCTAssertEqual(battery.detailRows.map(\.value), ["放电中", "11.4 W"], "PPBR only as a third-level reference")
        XCTAssertTrue(battery.note.contains("依据电池电流"))
        XCTAssertFalse(battery.note.contains("正值为充电"), "charging is not measured; the sign follows the current")
        let input = try XCTUnwrap(rows.first { $0.id == "power-input" })
        XCTAssertEqual(input.detailRows.map(\.title), ["输入电压", "输入电流", "协商功率"])
        XCTAssertEqual(input.detailRows.first?.value, "19.4 V", "D128: was 19.43 V")
        let backlight = try XCTUnwrap(rows.first { $0.id == "power-backlight" })
        XCTAssertEqual(backlight.source, "SMC PDBR")
        XCTAssertEqual(backlight.detailRows.first?.value, "382 尼特")
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        XCTAssertEqual(chip.detailRows.map(\.title), [
            "CPU", "超级核心簇", "性能核心簇", "GPU", "神经网络引擎", "内存", "内存控制器", "显示引擎", "媒体", "片上互连",
            "校验：系统控制器估计",
        ])
        // D128: iStat's zero power is "0 W" (was "0.00 W").
        XCTAssertEqual(chip.detailRows.first { $0.title == "神经网络引擎" }?.value, "0 W", "legal zero")
        XCTAssertEqual(
            chip.detailRows.filter(\.isIndented).map(\.title), ["超级核心簇", "性能核心簇"],
            "the clusters are parts of the CPU row, not more terms of the total"
        )
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        let detail = try MiniWindowLogicFixtures.section(view, from: "struct GeekSensorReadoutDetail: View {", to: "struct GeekDetailedTemperaturesDetail")
        XCTAssertTrue(detail.contains(".padding(.leading, row.isIndented ? GeekSensorReadoutLayout.childIndent : 0)"))
        XCTAssertGreaterThan(GeekSensorReadoutLayout.childIndent, 0)
    }

    /// D57 supplement: without a CPU part the chip total is not shown; the
    /// row only leads to the blocks this Mac measures, CPU under "本机不支持".
    func testWithoutACPUPartTheChipRowShowsNoTotal() throws {
        var withoutCPU = telemetry(.m5Pro)
        withoutCPU.soc = SoCPowerReading.make(
            channelPowers: ["GPU Energy": 0.44, "ANE0": 0, "DRAM0": 1.35].mapValues { SoCChannelPower(watts: $0, isUpdating: false) },
            performanceLevelNames: ["Super", "Performance"]
        )
        let rows = GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: withoutCPU, electrical: nil, now: Self.now
        )
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        XCTAssertEqual(chip.value, "本机不支持", "1.79 W of GPU, ANE and memory is not the chip total")
        XCTAssertFalse(chip.detailRows.contains { $0.id == "cpu" })
        XCTAssertEqual(chip.detailRows.map(\.title).prefix(3), ["GPU", "神经网络引擎", "内存"])
        XCTAssertTrue(chip.detailRows.allSatisfy { !$0.isIndented })
        let unsupported = try XCTUnwrap(chip.detailRows.first { $0.id == "unsupported" })
        XCTAssertEqual(unsupported.value, "CPU、内存控制器、显示引擎、媒体、片上互连")
        XCTAssertTrue(chip.note.contains("不显示芯片合计"))
    }

    func testUltraChannelNamesGiveAChipTotalWithTheCPU() throws {
        var ultra = telemetry(.m5Pro)
        ultra.soc = SoCPowerReading.make(
            channelPowers: [
                "DIE_0_CPU Energy": 9, "DIE_1_CPU Energy": 7, "DIE_0_PCPU0": 8, "DIE_0_ECPU": 1,
                "DIE_1_PCPU0": 6.5, "DIE_1_ECPU": 0.5, "GPU Energy": 12, "DIE_0_DRAM0": 2,
            ].mapValues { SoCChannelPower(watts: $0, isUpdating: false) },
            performanceLevelNames: ["Performance", "Efficiency"]
        )
        let rows = GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: ultra, electrical: nil, now: Self.now
        )
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        // D128 (2026-10-19): iStat's sensor format (was "30.00 W", "16.00 W").
        XCTAssertEqual(chip.value, "30 W", "CPU 16 + GPU 12 + memory 2, not the GPU and memory alone")
        XCTAssertEqual(chip.detailRows.first?.title, "CPU")
        XCTAssertEqual(chip.detailRows.first?.value, "16 W")
        XCTAssertEqual(chip.detailRows.filter(\.isIndented).map(\.title), ["性能核心簇", "能效核心簇"])
    }

    /// D57 supplement: the battery row is B0AP signed by B0AC; PPBR alone
    /// does not make a battery row.
    func testBatteryRowIsB0APWithTheCurrentsDirectionAndPPBROnlyAReference() throws {
        func batteryRow(_ change: (inout MiniSensorsDecodingTests.SMCFixture) -> Void) -> GeekSensorReadout? {
            var profile = Profile.m5Pro
            change(&profile.smc)
            return GeekPowerReadouts.rows(
                hasInternalBattery: true, powerSource: .acPower, telemetry: telemetry(profile), electrical: nil, now: Self.now
            ).first { $0.id == "power-battery" }
        }
        let charging = try XCTUnwrap(batteryRow {
            $0.keys["B0AC"] = .init("si16", "e204") // +1 250 mA
            $0.keys["B0AP"] = .init("si32", "283c0000") // +15 400 mW
        })
        XCTAssertEqual(charging.value, "+15.40 W")
        XCTAssertEqual(charging.detailRows.first?.value, "充电中")

        let override = try XCTUnwrap(batteryRow { $0.keys["B0AP"] = .init("si32", "ff290000") })
        XCTAssertEqual(override.value, "-10.75 W", "B0AC's direction, not B0AP's own sign")

        let noRail = try XCTUnwrap(batteryRow { $0.keys["PPBR"] = nil })
        XCTAssertEqual(noRail.value, "-10.75 W")
        XCTAssertEqual(noRail.detailRows.last?.value, "本机不支持")

        let noCurrent = try XCTUnwrap(batteryRow { $0.keys["B0AC"] = nil })
        XCTAssertEqual(noCurrent.value, "-10.75 W", "B0AP's own sign without B0AC")
        XCTAssertEqual(noCurrent.detailRows.first?.value, "本机不支持")
        let idle = try XCTUnwrap(batteryRow { $0.keys["B0AC"] = .init("si16", "0000") })
        XCTAssertEqual(idle.detailRows.first?.value, "电流约为 0")

        // Incremental review P2-2: without B0AP the row is B0AV × B0AC.
        let computed = try XCTUnwrap(batteryRow { $0.keys["B0AP"] = nil })
        XCTAssertEqual(computed.value, "-10.28 W", "12.302 V × -0.836 A")
        XCTAssertEqual(computed.source, "电压 × 电流（SMC）")
        XCTAssertTrue(computed.note.contains("B0AV × B0AC"))
        XCTAssertEqual(computed.detailRows.map(\.value), ["放电中", "11.4 W"], "D128: was 11.43 W")
        XCTAssertNil(
            batteryRow { $0.keys["B0AP"] = nil; $0.keys["B0AV"] = nil; $0.keys["B0AC"] = nil },
            "PPBR alone is not the battery row"
        )
    }

    /// Incremental review P2-3: the "整机" note said nothing about charging.
    /// Measured (handoff §14): PSTR ≈ PDTR − B0AP, so on external power it
    /// does not include the power charging the battery; on battery the
    /// battery supplies all of it. Chinese and English.
    func testComputerRowNoteSaysWhatPSTRIncludes() throws {
        func note(_ powerSource: BatteryPowerSource?, battery: Bool = true) throws -> String {
            try XCTUnwrap(GeekPowerReadouts.rows(
                hasInternalBattery: battery, powerSource: powerSource, telemetry: telemetry(.m5Pro), electrical: nil, now: Self.now
            ).first { $0.id == "power-system" }).note
        }
        let charging = try note(.acPower)
        XCTAssertTrue(charging.contains("接电源时不含给电池充电的部分"), charging)
        XCTAssertTrue(charging.contains("电源输入减去充电功率"), charging)
        XCTAssertFalse(charging.contains("含给电池充电的部分") && !charging.contains("不含给电池充电的部分"))
        let onBattery = try note(.batteryPower)
        XCTAssertTrue(onBattery.hasSuffix("用电池时全部由电池供电"), onBattery)
        XCTAssertFalse(onBattery.contains("电源输入"))
        XCTAssertEqual(try note(.acPower, battery: false), "整机耗电功率，约每秒更新", "a desktop has no battery to charge")
        XCTAssertEqual(try note(nil), "整机耗电功率，约每秒更新")

        let english = MiniWindowLogicLanguageScope(.english)
        defer { english.restore() }
        XCTAssertTrue(try note(.acPower).contains("does not include the power charging the battery"))
        XCTAssertTrue(try note(.batteryPower).hasSuffix("on battery all of it comes from the battery"))
    }

    func testOnBatteryThePowerInputRowIsNotShown() {
        XCTAssertEqual(rows(profile: .m5Pro, powerSource: .batteryPower).map(\.title), ["整机", "电池", "屏幕背光", "芯片合计"])
    }

    func testM5BaseUsesPBwoAndListsItsEfficiencyCluster() throws {
        let rows = rows(profile: .m5Base, powerSource: .acPower)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "power-backlight" }).source, "SMC PBwo")
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        XCTAssertTrue(chip.detailRows.map(\.title).contains("超级核心簇"))
        XCTAssertTrue(chip.detailRows.map(\.title).contains("能效核心簇"))
        XCTAssertFalse(chip.detailRows.map(\.title).contains("性能核心簇"))
    }

    func testM1ToM4LaptopWithoutBacklightKeysHidesTheRowAndNamesMissingBlocks() throws {
        let rows = rows(profile: .m1ToM4WithoutBacklight, powerSource: .acPower)
        XCTAssertEqual(rows.map(\.title), ["整机", "电源输入", "电池", "芯片合计"], "no backlight key: hidden")
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        let titles = chip.detailRows.map(\.title)
        XCTAssertTrue(titles.contains("性能核心簇"))
        XCTAssertTrue(titles.contains("能效核心簇"))
        XCTAssertFalse(titles.contains("神经网络引擎"), "a missing channel is not listed as a value")
        let unsupported = try XCTUnwrap(chip.detailRows.first { $0.id == "unsupported" })
        XCTAssertEqual(unsupported.title, "本机不支持")
        XCTAssertEqual(unsupported.value, "神经网络引擎、显示引擎")
    }

    func testDesktopShowsOnlyWhatItMeasures() {
        let rows = GeekPowerReadouts.rows(
            hasInternalBattery: false,
            powerSource: .acPower,
            telemetry: telemetry(.desktop),
            electrical: nil,
            now: Self.now
        )
        XCTAssertEqual(rows.map(\.title), ["整机", "芯片合计"], "no PDTR, battery or backlight keys")
    }

    func testOutOfRangeValuesShowADashAndSayInvalid() throws {
        let rows = rows(profile: .invalidReadings, powerSource: .acPower)
        let system = try XCTUnwrap(rows.first { $0.id == "power-system" })
        XCTAssertEqual(system.value, "—")
        XCTAssertTrue(system.note.hasPrefix("读数无效"))
        let backlight = try XCTUnwrap(rows.first { $0.id == "power-backlight" })
        XCTAssertEqual(backlight.value, "—", "9 W against 4.67 W: the check fails")
        XCTAssertTrue(backlight.note.contains("核对不一致"))
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        XCTAssertEqual(chip.value, "—")
    }

    func testLegalZerosAreShown() throws {
        let rows = rows(profile: .zeros, powerSource: .acPower)
        // D128: iStat's zero power (was "0.00 W"); the signed battery row is ours.
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "power-backlight" }).value, "0 W", "dark display")
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "power-battery" }).value, "0.00 W", "idle battery")
        XCTAssertEqual(HardwareReadingText.signedAmps(0), "0.00 A", "a zero current has no sign")
        XCTAssertEqual(HardwareReadingText.signedAmps(-0.836), "-0.84 A")
        XCTAssertEqual(HardwareReadingText.signedWatts(0.001), "0.00 W")
    }

    /// Review item 7: the power history's third level showed a zero as
    /// "+0.000 A / +0.00 W". Zeros have no sign anywhere the battery's
    /// current or power is shown with one.
    func testSignedZerosHaveNoSignInThePowerHistory() throws {
        XCTAssertEqual(HardwareReadingText.signed(0, decimals: 3, unit: "A"), "0.000 A")
        XCTAssertEqual(HardwareReadingText.signed(0.0004, decimals: 3, unit: "A"), "0.000 A")
        XCTAssertEqual(HardwareReadingText.signed(-0.0004, decimals: 3, unit: "A"), "0.000 A")
        XCTAssertEqual(HardwareReadingText.signed(-0.0, decimals: 3, unit: "A"), "0.000 A")
        XCTAssertEqual(HardwareReadingText.signed(0.8421, decimals: 3, unit: "A"), "+0.842 A")
        XCTAssertEqual(HardwareReadingText.signed(-0.8421, decimals: 3, unit: "A"), "-0.842 A")
        XCTAssertEqual(HardwareReadingText.signedWatts(0), "0.00 W")
        XCTAssertEqual(HardwareReadingText.signedWatts(-0.004), "0.00 W")
        XCTAssertEqual(HardwareReadingText.signedWatts(28), "+28.00 W")
        XCTAssertEqual(GeekPowerHistoryMetric.batteryPower.formatted(0), "0.00 W", "history tooltip")
        XCTAssertEqual(GeekPowerHistoryMetric.batteryPower.formatted(-6.29), "-6.29 W")

        for path in [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift",
        ] {
            let source = try MiniWindowLogicFixtures.source(path)
            XCTAssertFalse(source.contains("String(format: \"%+.3f A\""), path)
            XCTAssertFalse(source.contains("String(format: \"%+.2f W\""), path)
            XCTAssertTrue(source.contains("HardwareReadingText.signedWatts("), path)
        }
        let detail = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        XCTAssertTrue(detail.contains("HardwareReadingText.signed(current, decimals: 3, unit: \"A\")"))
    }

    func testFirstWindowAndStaleTelemetrySayUpdating() throws {
        var first = telemetry(.m5Pro)
        first.soc = SoCPowerReading.make(
            channelPowers: Profile.m5Pro.channelWatts.mapValues { _ in SoCChannelPower(watts: nil, isUpdating: true) },
            performanceLevelNames: ["Super", "Performance"]
        )
        let rows = GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: first, electrical: nil, now: Self.now
        )
        let chip = try XCTUnwrap(rows.first { $0.id == "power-chip" })
        XCTAssertEqual(chip.value, "更新中…", "never 0 W before the first window")
        XCTAssertTrue(chip.isUpdating)

        let stale = GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: telemetry(.m5Pro), electrical: nil,
            now: Self.now.addingTimeInterval(30)
        )
        XCTAssertTrue(stale.allSatisfy(\.isUpdating), "a kept reading is marked until replaced")
        XCTAssertEqual(stale.first?.value, "87.9 W", "D128: was 87.90 W")
        XCTAssertTrue(GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: nil, electrical: nil
        ).isEmpty)
    }

    func testEnergyModelUnavailableHidesTheChipRow() {
        var withoutEnergyModel = telemetry(.m5Pro)
        withoutEnergyModel.soc = .unsupported
        let rows = GeekPowerReadouts.rows(
            hasInternalBattery: true, powerSource: .acPower, telemetry: withoutEnergyModel, electrical: nil, now: Self.now
        )
        XCTAssertFalse(rows.contains { $0.id == "power-chip" })
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    /// The review's screenshot scenarios use the demo's real magnitudes:
    /// an Ultra's per-die names give the same CPU as the demo, without a
    /// CPU channel there is no total. (The demo data exists only in Debug
    /// and Beta builds.)
    func testReviewDemoScenariosForTheChipBreakdown() throws {
        let ultra = MiniWindowDemoData.socPowerReading(channelWatts: MiniWindowDemoData.ultraPowerChannelWatts)
        XCTAssertEqual(try XCTUnwrap(ultra.cpu?.watts), 13.33, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ultra.total?.watts), 20.49, accuracy: 0.001)
        XCTAssertEqual(ultra.unsupportedComponents, [])
        let withoutCPU = MiniWindowDemoData.socPowerReading(channelWatts: MiniWindowDemoData.powerChannelWattsWithoutCPU)
        XCTAssertNil(withoutCPU.total)
        XCTAssertEqual(withoutCPU.unsupportedComponents, [.cpu])
        XCTAssertFalse(withoutCPU.items.isEmpty)
    }

    /// Incremental review item 4: the demo's PPBR was 1.06 × B0AP, but while
    /// charging the real PPBR is a small, nearly fixed value (0.6-2.8 W).
    func testDemoBatteryRailFollowsTheMeasuredRatios() {
        XCTAssertEqual(MiniWindowDemoData.batteryRailWatts(batteryWatts: 28), 1.43, "charging: about 1.4 W")
        XCTAssertEqual(MiniWindowDemoData.batteryRailWatts(batteryWatts: -6.29), 6.29 * 1.59, accuracy: 1e-9)
        XCTAssertEqual(MiniWindowDemoData.batteryRailWatts(batteryWatts: 0), 0)
        XCTAssertLessThan(MiniWindowDemoData.batteryRailWatts(batteryWatts: 28), 28 * 0.2)
    }
    #endif

    // MARK: - Battery card and battery hover

    func testBatteryElectricalRowsFollowTheRule() throws {
        let smc = SMCPowerTelemetryService.batteryTelemetry(read: Profile.m5Pro.smc.read, platform: .appleSilicon)
        let live = try XCTUnwrap(NativeBatteryElectricalService.snapshot(properties: ["Voltage": 12_311], smcBattery: smc))
        let rows = GeekBatteryElectricalReadouts.rows(electrical: live)
        // D128: iStat's voltage (was "12.30 V"); the signed current is ours.
        XCTAssertEqual(rows.map(\.value), ["-0.84 A", "12.3 V"])
        XCTAssertEqual(rows.map(\.source), ["SMC B0AC", "SMC B0AV"])

        var broken = Profile.m5Pro.smc
        broken.keys["B0AV"] = .init("ui16", "0000")
        broken.keys["B0AC"] = nil
        let partial = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["CurrentCapacity": 80],
            smcBattery: SMCPowerTelemetryService.batteryTelemetry(read: broken.read, platform: .appleSilicon)
        ))
        let partialRows = GeekBatteryElectricalReadouts.rows(electrical: partial)
        XCTAssertEqual(partialRows.map(\.title), ["电池电压"], "no B0AC and no controller current: hidden")
        XCTAssertEqual(partialRows.first?.value, "—")
    }

    func testBatteryHoverRowsUseTheRuleInTheThirdLevel() {
        XCTAssertEqual(GeekBatteryHoverReadings.cellRows([]).map(\.1), ["本机不支持"])
        // D128 (2026-10-19): iStat's battery submenu formats cell voltages as
        // sensor type 6, at most one decimal (was "4.095 V", "4.102 V").
        XCTAssertEqual(
            GeekBatteryHoverReadings.cellRows([.value(4.095), .invalid, .value(4.102)]).map { "\($0.0) \($0.1)" },
            ["电芯 1 4.1 V", "电芯 2 读数无效", "电芯 3 4.1 V"]
        )
        XCTAssertEqual(GeekBatteryHoverReadings.usbPowerOutRows(.unsupported).map(\.1), ["本机不支持"])
        XCTAssertEqual(GeekBatteryHoverReadings.usbPowerOutRows(.invalid).map(\.1), ["读数无效"])
        // D128: iStat's power format (was "0.00 W" and "1.26 W").
        XCTAssertEqual(GeekBatteryHoverReadings.usbPowerOutRows(.value([])).map(\.1), ["0 W"], "legal zero")
        XCTAssertEqual(
            GeekBatteryHoverReadings.usbPowerOutRows(.value([
                USBPowerOutPort(portIndex: 2, watts: 1.258), USBPowerOutPort(portIndex: 3, watts: 0),
            ])).map { "\($0.0) \($0.1)" },
            ["端口 2 1.3 W"], "only ports that supply power"
        )
        XCTAssertEqual(HardwareReadingText.detail(HardwareReading<Double>.unsupported, format: HardwareReadingText.celsius), "本机不支持")
        XCTAssertEqual(HardwareReadingText.detail(HardwareReading<Double>.invalid, format: HardwareReadingText.celsius), "读数无效")
        // D128: iStat's whole degrees (was "36.7°C").
        XCTAssertEqual(HardwareReadingText.detail(HardwareReading.value(36.7), format: HardwareReadingText.celsius), "37°")
    }

    // MARK: - Sensors page

    func testPowerManagementICIsNotTheCPU() throws {
        let hid = [
            AppleSiliconTemperatureService.Reading(name: "PMU tdie1", value: 82.4),
            AppleSiliconTemperatureService.Reading(name: "PMU tdie8", value: 88.7),
            AppleSiliconTemperatureService.Reading(name: "PMU tdev1", value: -9_201),
            AppleSiliconTemperatureService.Reading(name: "PMU tcal", value: 51.8),
            AppleSiliconTemperatureService.Reading(name: "gas gauge battery", value: 36.0),
            AppleSiliconTemperatureService.Reading(name: "NAND CH0 temp", value: 48),
        ]
        XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: hid), "M5: no HID CPU sensor")
        XCTAssertNil(AppleSiliconTemperatureService.regionalTemperatures(from: hid).first { $0.zone == .chip })
        // D81 retains the two physical PMU dies; the separate summary helper still returns the hottest.
        let pmu = AppleSiliconTemperatureService.detailedTemperatures(from: hid).filter {
            $0.channel?.rawName.hasPrefix("PMU tdie") == true
        }
        XCTAssertEqual(pmu.count, 2)
        XCTAssertEqual(Set(pmu.map(\.celsius)), [82.4, 88.7])
        XCTAssertTrue(pmu.allSatisfy { $0.name.hasPrefix("电源管理芯片") && $0.zone == nil })
        XCTAssertFalse(AppleSiliconTemperatureService.detailedTemperatures(from: hid).contains { $0.name.hasPrefix("PMU") })
    }

    func testCPURowReadsTheRingValueAndTheProbesListThePMU() throws {
        let smc = Profile.m5ProTemperatures
        let readings = SMCFanSpeedService.temperatureReadings(readValue: { smc[$0] }, platform: .appleSilicon)
        var hottest: [SystemTemperatureZone: Double] = [:]
        for reading in readings { hottest[reading.zone] = reading.celsius }
        let chip = try XCTUnwrap(SMCFanSpeedService.chipTemperatureCelsius { smc[$0] })
        let regional = SystemMonitorService.regionalTemperatures(hottestByZone: hottest, chipTemperatureCelsius: chip)
        XCTAssertEqual(regional.first, SystemTemperatureReading(zone: .chip, celsius: 102.2), "the hottest Tp core, like the ring")
        XCTAssertEqual(try XCTUnwrap(regional.first { $0.zone == .chargingCircuit }?.celsius), 57.1346, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(regional.first { $0.zone == .palmRest }?.celsius), 32.969, accuracy: 0.001, "Ts0P/Ts1P")
        XCTAssertEqual(
            SMCFanSpeedService.inferredTemperatureZones { smc[$0] },
            [.palmRest, .thunderboltLeft, .thunderboltRight]
        )

        let details = SystemMonitorService.detailedTemperatures(
            smcDetails: SMCFanSpeedService.detailedTemperatureReadings { smc[$0] },
            smcPowerManagementCelsius: SMCFanSpeedService.powerManagementTemperatureCelsius { smc[$0] },
            hidReadings: []
        )
        XCTAssertEqual(details.last?.name, "电源管理芯片")
        XCTAssertEqual(try XCTUnwrap(details.last?.celsius), 96.0987, accuracy: 0.0001, "SMC TPDX/TRDX/TUDX without HID")
        let rows = GeekTemperatureRowDetail.rows(zone: .chip, celsius: 102.2, details: details)
        XCTAssertEqual(rows.map(\.title), ["最高", "平均（18 个传感器）"], "sensors, not cores (review item 9)")
        // D128 (2026-10-19): iStat's whole degrees (was "102.2°C", "91.0°C").
        XCTAssertEqual(rows.first?.value, "102°")
        XCTAssertEqual(rows.last?.value, "91°")
        XCTAssertTrue(GeekTemperatureRowDetail.rows(zone: .gpu, celsius: 80, details: details).isEmpty)
        XCTAssertEqual(GeekTemperatureRowDetail.note(zone: .palmRest, inferredZones: [.palmRest]), "依据键名推断：该位置的传感器没有公开定义")
        XCTAssertNil(GeekTemperatureRowDetail.note(zone: .palmRest, inferredZones: []))
    }

    /// Review item 9: M1–M4 have a few probes per cluster, not one per
    /// core; the average names the sensors it is taken over.
    func testCPUAverageOnM1ToM4CountsClusterSensors() {
        let details = [70.0, 72, 74, 76].enumerated().map {
            SystemTemperatureDetailReading(id: "p\($0.offset)", name: "P\($0.offset)", zone: .performanceCores, celsius: $0.element)
        } + [60.0, 62].enumerated().map {
            SystemTemperatureDetailReading(id: "e\($0.offset)", name: "E\($0.offset)", zone: .efficiencyCores, celsius: $0.element)
        }
        let rows = GeekTemperatureRowDetail.rows(zone: .chip, celsius: 76, details: details)
        XCTAssertEqual(rows.map(\.title), ["最高", "平均（6 个传感器）"])
        XCTAssertEqual(rows.last?.value, "69°", "D128: was 69.0°C")
    }

    func testChassisKeysNeedTheM5TopologyAndChargingCircuitNeedsAppleSilicon() {
        let withoutTopology: [String: Double] = ["Ts0P": 34, "Ts1P": 32, "TaLT": 45, "TCHP": 57, "TDeL": 39]
        let readings = SMCFanSpeedService.temperatureReadings(readValue: { withoutTopology[$0] }, platform: .appleSilicon)
        XCTAssertEqual(readings.map(\.zone), [.chargingCircuit])
        XCTAssertTrue(SMCFanSpeedService.inferredTemperatureZones { withoutTopology[$0] }.isEmpty)
        XCTAssertTrue(SMCFanSpeedService.temperatureReadings(readValue: { withoutTopology[$0] }, platform: .intel).isEmpty,
                      "TCHP is only the charge regulator on Apple silicon")
        var m5 = Profile.m5ProTemperatures
        m5["Ts0P"] = nil
        m5["Ts1P"] = nil
        let palm = SMCFanSpeedService.temperatureReadings(readValue: { m5[$0] }, platform: .appleSilicon)
        XCTAssertNil(palm.first { $0.zone == .palmRest }, "TDeL/TDeR are no longer read as palm rest")
    }

    func testAmbientLightRow() {
        XCTAssertNil(GeekAmbientLightReadout.readout(nil, sampledAt: nil))
        XCTAssertNil(GeekAmbientLightReadout.readout(.unsupported, sampledAt: nil))
        // D128 (2026-10-19): iStat's light sensor (type 7) unit (was "161 lx", "0 lx").
        XCTAssertEqual(GeekAmbientLightReadout.readout(.value(161), sampledAt: nil)?.value, "161 Lux")
        XCTAssertEqual(GeekAmbientLightReadout.readout(.value(0), sampledAt: nil)?.value, "0 Lux")
        let invalid = GeekAmbientLightReadout.readout(.invalid, sampledAt: nil)
        XCTAssertEqual(invalid?.value, "—")
        XCTAssertEqual(invalid?.note.hasPrefix("读数无效"), true)
        XCTAssertEqual(invalid?.title, "光照")
    }

    func testTemperatureZoneOrderPlacesTheChargingCircuitAfterTheBattery() {
        XCTAssertEqual(
            GeekTemperatureZoneLayout.displayZones(available: [.wifi, .chargingCircuit, .battery, .chip, .palmRest]),
            [.chip, .battery, .chargingCircuit, .palmRest, .wifi]
        )
        XCTAssertEqual(MenuBarTelemetryChannel.temperature(.chargingCircuit), .chargingCircuitTemperature)
    }

    // MARK: - Sampling and read-only access

    func testPowerTelemetryIsSampledOnlyForThePowerPageAndOffTheMainThread() async throws {
        XCTAssertTrue(PanelDensity.geek.auxiliaryDemand(for: .power).needsPowerTelemetry)
        // D119 (2026-10-18): the sensors page's power group reads the same
        // telemetry, so it samples there too; every other page stays off.
        XCTAssertTrue(PanelDensity.geek.auxiliaryDemand(for: .sensors).needsPowerTelemetry)
        for section in [PanelSection.overview, .processor, .memory, .disk, .network] {
            XCTAssertFalse(PanelDensity.geek.auxiliaryDemand(for: section).needsPowerTelemetry, "\(section)")
        }

        let probe = PowerSamplingProbe()
        let state = MenuBarAuxiliaryMonitorState(
            batteryAvailabilityProvider: { .present },
            diskCounterProvider: { nil },
            storageVolumeProvider: { .empty },
            batterySnapshotProvider: { (nil, nil) },
            publicNetworkConsentProvider: { false },
            networkProcessProvider: { nil },
            powerTelemetryProvider: { probe.sample() },
            powerTelemetryPause: { probe.pause() },
            powerHistoryURL: nil
        )
        defer { state.setPaused(true) }
        func demand(power: Bool) -> MenuBarAuxiliaryMonitorDemand {
            MenuBarAuxiliaryMonitorDemand(
                needsProcessorTelemetry: false, needsDiskIOSampling: false, needsNetworkInterface: false,
                needsPublicNetworkAddress: false, needsNetworkProcesses: false, needsPowerTelemetry: power
            )
        }
        let consumer = UUID()
        state.registerConsumer(consumer, demand: demand(power: false), paused: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(probe.sampleCount, 0, "no power reads off the power and sensors pages")
        XCTAssertNil(state.powerTelemetry)

        state.updateConsumer(consumer, demand: demand(power: true))
        for _ in 0..<50 where state.powerTelemetry == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(probe.sampleCount, 1)
        XCTAssertFalse(probe.sampledOnMainThread, "sampling runs on a background task")
        XCTAssertNotNil(state.powerTelemetry)

        state.updateConsumer(consumer, demand: demand(power: false))
        for _ in 0..<50 where probe.pauseCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(probe.pauseCount, 1, "leaving the page resets the Energy Model baseline")
        XCTAssertNotNil(state.powerTelemetry, "the last reading is kept and later shown as updating")
        state.unregisterConsumer(consumer)
    }

    /// The power history's third level listed the adapter's negotiated
    /// rating as "输入功率/电压/电流" (research §3.5); D57 separates them.
    func testPowerHistoryDetailSeparatesMeasuredInputFromTheNegotiatedRating() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let detail = try MiniWindowLogicFixtures.section(source, from: "private var tertiaryPowerDetail", to: "if hasInternalBattery {")
        XCTAssertTrue(detail.contains("let input = powerTelemetry?.smc"))
        XCTAssertTrue(detail.contains("input?.inputPowerWatts.value"))
        // D128 (2026-10-19): iStat's power format (was `String(format: "%.0f W", adapterPower)`).
        XCTAssertTrue(detail.contains("L10n.text(\"协商功率\", \"Negotiated Power\"), value: IStatNumberFormat.power(adapterPower)"))
        XCTAssertFalse(
            detail.contains("L10n.text(\"输入功率\", \"Input Power\"), value: IStatNumberFormat.power(adapterPower)"),
            "the negotiated rating is not labelled as the measured input"
        )
    }

    func testSMCAndIOReportAccessIsReadOnly() throws {
        let smc = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SMCFanSpeedService.swift")
        let commands = try MiniWindowLogicFixtures.section(smc, from: "private enum Command: UInt8 {", to: "}")
        let selectors = commands.components(separatedBy: "=").dropFirst().compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber })
        }
        XCTAssertEqual(selectors.sorted(), [2, 5, 8, 9], "kernel index and the read selectors only; 6 writes")
        let power = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SMCPowerTelemetryService.swift")
        XCTAssertFalse(power.contains("IOConnectCallStructMethod"))
        XCTAssertFalse(power.contains("IORegistryEntrySetCFProperty"))
        XCTAssertFalse(power.contains("dlsym("))

        let ioreport = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/CPUPerformanceStateService.swift")
        // Every libIOReport function the file loads (`load("IOReport…"`).
        let used = Set(ioreport.components(separatedBy: "load(\n            \"IOReport").dropFirst().map { "IOReport" + $0.prefix { $0 != "\"" } }
            + ioreport.components(separatedBy: "load(\"IOReport").dropFirst().map { "IOReport" + $0.prefix { $0 != "\"" } })
        XCTAssertGreaterThanOrEqual(used.count, 11)
        let readOnly: Set<String> = [
            "IOReportCopyChannelsInGroup", "IOReportCreateSubscription", "IOReportCreateSamples",
            "IOReportCreateSamplesDelta", "IOReportChannelGetChannelName", "IOReportChannelGetSubGroup",
            "IOReportStateGetCount", "IOReportStateGetNameForIndex", "IOReportStateGetResidency",
            "IOReportChannelGetUnitLabel", "IOReportSimpleGetIntegerValue",
        ]
        XCTAssertEqual(used.subtracting(readOnly), [], "only copy, subscribe, sample and value reads")
        let estimator = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SoCPowerTelemetry.swift")
        XCTAssertFalse(estimator.contains("dlopen("))
        XCTAssertFalse(estimator.contains("dlsym("))
    }

    // MARK: - Fixtures

    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func rows(profile: Profile, powerSource: BatteryPowerSource) -> [GeekSensorReadout] {
        GeekPowerReadouts.rows(
            hasInternalBattery: true,
            powerSource: powerSource,
            telemetry: telemetry(profile),
            electrical: NativeBatteryElectricalService.snapshot(properties: ["AdapterDetails": ["Watts": 65]]),
            now: Self.now
        )
    }

    private func telemetry(_ profile: Profile) -> MenuBarPowerTelemetry {
        MenuBarPowerTelemetry(
            smc: SMCPowerTelemetryService.telemetry(read: profile.smc.read, platform: .appleSilicon),
            backlightBrightnessNits: .value(381.794),
            soc: SoCPowerReading.make(
                channelPowers: profile.channelWatts.mapValues {
                    $0.isFinite ? SoCChannelPower(watts: $0, isUpdating: false)
                        : SoCChannelPower(watts: nil, isUpdating: false, isInvalid: true)
                },
                performanceLevelNames: profile.performanceLevels
            ),
            generatedAt: Self.now
        )
    }

    struct Profile {
        var smc: MiniSensorsDecodingTests.SMCFixture
        var channelWatts: [String: Double]
        var performanceLevels: [String]

        /// The research's "空闲 2" Energy Model phase (total 18.8 W).
        static let m5ProChannels: [String: Double] = [
            "CPU Energy": 13.33, "PCPU": 11.42, "MCPU0": 1.05, "MCPU1": 0.85, "GPU Energy": 0.44, "ANE0": 0,
            "DRAM0": 1.35, "AMCC0": 1.01, "DCS0": 1.30, "DISP0": 0.32, "DISPEXT0": 0.12,
            "ISP0": 0.02, "AVE0": 0.02, "MSR0": 0.02, "FAB0": 0.74, "AFR0": 0.13,
        ]

        static let m5Pro = Profile(
            smc: MiniSensorsDecodingTests.mac17_9, channelWatts: m5ProChannels,
            performanceLevels: ["Super", "Performance"]
        )

        static var m5Base: Profile {
            var smc = MiniSensorsDecodingTests.mac17_9
            smc.keys["PBwo"] = smc.keys["PDBR"]
            smc.keys["PDBR"] = nil
            var channels = m5ProChannels
            channels["MCPU0"] = nil
            channels["MCPU1"] = nil
            channels["ECPU"] = 1.9
            return Profile(smc: smc, channelWatts: channels, performanceLevels: ["Super", "Efficiency"])
        }

        static var m1ToM4WithoutBacklight: Profile {
            var smc = MiniSensorsDecodingTests.mac17_9
            for key in ["PDBR", "PBwo", "IDBR", "VP0R"] { smc.keys[key] = nil }
            var channels = m5ProChannels
            for key in ["MCPU0", "MCPU1", "ANE0", "DISP0", "DISPEXT0"] { channels[key] = nil }
            channels["ECPU"] = 1.9
            return Profile(smc: smc, channelWatts: channels, performanceLevels: ["Performance", "Efficiency"])
        }

        static var desktop: Profile {
            var smc = MiniSensorsDecodingTests.mac17_9
            for key in ["PDTR", "VD0R", "ID0R", "PPBR", "PDBR", "IDBR", "VP0R", "B0AC", "B0AV", "B0AP", "B0AT", "TB0T", "BC1V", "BC2V", "BC3V"] {
                smc.keys[key] = nil
            }
            return Profile(smc: smc, channelWatts: m5ProChannels, performanceLevels: ["Performance", "Efficiency"])
        }

        static var invalidReadings: Profile {
            var smc = MiniSensorsDecodingTests.mac17_9
            smc.keys["PSTR"] = .init("flt ", "00409c45") // 5 000 W
            smc.keys["PDBR"] = .init("flt ", "00001041") // 9 W against 4.67 W
            var channels = m5ProChannels
            channels["DRAM0"] = .nan
            return Profile(smc: smc, channelWatts: channels, performanceLevels: ["Super", "Performance"])
        }

        static var zeros: Profile {
            var smc = MiniSensorsDecodingTests.mac17_9
            smc.keys["PDBR"] = .init("flt ", "00000000")
            smc.keys["IDBR"] = .init("flt ", "00000000")
            smc.keys["PPBR"] = .init("flt ", "00000000")
            smc.keys["B0AP"] = .init("si32", "00000000")
            return Profile(smc: smc, channelWatts: m5ProChannels, performanceLevels: ["Super", "Performance"])
        }

        /// Mac17,9's temperature keys (research §4.1, idle1 snapshot).
        static let m5ProTemperatures: [String: Double] = {
            var values: [String: Double] = [
                "Tp00": 102.2, "Tp04": 98.4, "Tp08": 95.0, "Tp0C": 96.3, "Tp0G": 97.1, "Tp0K": 99.0,
                "Tp0O": 92.1, "Tp0R": 88.4, "Tp0U": 89.0, "Tp0X": 87.2, "Tp0a": 86.0, "Tp0d": 85.5,
                "Tp0g": 86.9, "Tp0j": 88.1, "Tp0m": 87.7, "Tp0p": 86.4, "Tp0u": 85.9, "Tp0y": 86.6,
                "Tg08": 80.0, "Tg43": 82.0,
                "TCHP": 57.1346, "Ts0P": 34.125, "Ts1P": 31.8125, "TaLT": 45.6733, "TaRT": 38.0991,
                "TDeL": 39.125, "TDeR": 38.875, "TB0T": 36.7, "TH0x": 46.3164, "TW0P": 65.0139,
                "TaLP": 62.4884, "TaRF": 57.1635,
                "TPDX": 96.0987, "TRDX": 70.7518, "TUDX": 64.2751,
            ]
            values["Tp0K"] = 99.0
            return values
        }()
    }
}

/// Counts the injected power provider's calls.
private final class PowerSamplingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var pauses = 0
    private var onMain = false

    var sampleCount: Int { lock.withLock { samples } }
    var pauseCount: Int { lock.withLock { pauses } }
    var sampledOnMainThread: Bool { lock.withLock { onMain } }

    func sample() -> MenuBarPowerTelemetry {
        lock.withLock {
            samples += 1
            onMain = onMain || Thread.isMainThread
        }
        return MenuBarPowerTelemetry.unsupported(at: Date())
    }

    func pause() {
        lock.withLock { pauses += 1 }
    }
}
