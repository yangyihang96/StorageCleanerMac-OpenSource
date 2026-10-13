import XCTest
@testable import StorageCleanerMac

final class MenuBarSensorIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

    func testEqualNamesRemainIndependentChannelsAndDies() throws {
        let readings = [reading("CPU tdie", service: "die0", ordinal: 1, value: 30),
                        reading("CPU tdie", service: "die1", ordinal: 2, value: 80)]
        let details = AppleSiliconTemperatureService.detailedTemperatures(from: readings, now: now)
        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(Set(details.map(\.id)).count, 2)
        XCTAssertEqual(Set(details.map(\.name)).count, 2)
        XCTAssertEqual(Set(details.map(\.celsius)), [30, 80])
        XCTAssertEqual(Set(details.compactMap { $0.channel?.rawKey }), ["die0", "die1"])
        XCTAssertEqual(Set(details.compactMap(\.zone)), [.chip])
        XCTAssertTrue(details.allSatisfy { $0.sourceHelp.contains("HID") })
    }

    func testPMUDiesAreChannelsRatherThanOneNameMaximum() {
        let readings = [reading("PMU tdie1", service: "pmu0", ordinal: 3, value: 30),
                        reading("PMU tdie1", service: "pmu1", ordinal: 4, value: 70)]
        let details = AppleSiliconTemperatureService.detailedTemperatures(from: readings, now: now)
        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(Set(details.map(\.celsius)), [30, 70])
        XCTAssertTrue(details.allSatisfy { $0.zone == nil && $0.channel?.confidence == .recognized })
        XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings, now: now))
    }

    func testUnknownNamesDoNotGuessARegionAndRetainRawServiceInHelp() throws {
        let raw = "mysterious GPU-ish subsystem channel"
        let details = AppleSiliconTemperatureService.detailedTemperatures(from: [reading(raw, service: "raw-key-7", ordinal: 7, value: 42)], now: now)
        let detail = try XCTUnwrap(details.first)
        XCTAssertNil(detail.zone)
        XCTAssertEqual(detail.channel?.confidence, .unknown)
        XCTAssertEqual(detail.channel?.unit, "°C")
        XCTAssertTrue(detail.name.contains("未识别温度通道") || detail.name.contains("Unidentified Temperature Channel"))
        // Display numbers come from raw label/key order, not the cache ordinal.
        XCTAssertTrue(detail.name.hasSuffix(" 1"))
        XCTAssertEqual(detail.channel?.ordinal, 7)
        XCTAssertTrue(detail.sourceHelp.contains("raw-key-7"))
        XCTAssertTrue(detail.sourceHelp.contains(raw))
        XCTAssertTrue(AppleSiliconTemperatureService.regionalTemperatures(from: [reading(raw, service: "7", ordinal: 7, value: 42)], now: now).isEmpty)
        for ambiguous in [raw, "unknown die temp", "mysterious soc mtr temp", "PMU mystery tdie1", "uncertain tcal probe"] {
            let readings = [reading(ambiguous, service: "ambiguous", ordinal: 8, value: 99)]
            XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings, now: now))
            XCTAssertEqual(AppleSiliconTemperatureService.detailedTemperatures(from: readings, now: now).first?.channel?.confidence, .unknown)
        }
    }

    func testZeroMissingExpiredAndInvalidAreDistinct() {
        // Sampling keeps the original 5...130 °C floor: a raw 0 or fixed-point
        // 256 (1 °C) HID/SMC reading is not a measurement and never becomes 0/1 °C.
        let zero = reading("CPU tdie", service: "zero", ordinal: 1, value: 0)
        let valid = reading("CPU tdie", service: "valid", ordinal: 4, value: 41)
        var stale = reading("GPU tdie", service: "stale", ordinal: 2, value: 90)
        stale.sampledAt = now.addingTimeInterval(-181)
        let invalid = reading("CPU tdie", service: "invalid", ordinal: 3, value: .nan)
        let details = AppleSiliconTemperatureService.detailedTemperatures(from: [zero, valid, stale, invalid], now: now)
        XCTAssertEqual(details.map(\.celsius), [41])
        XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: [zero], now: now))
        XCTAssertNil(AppleSiliconTemperatureService.normalizedTemperature(rawValue: 0, sensorName: "CPU tdie"))
        XCTAssertNil(AppleSiliconTemperatureService.normalizedTemperature(rawValue: 256, sensorName: "PMU tdev4"))
        XCTAssertTrue(AppleSiliconTemperatureService.regionalTemperatures(from: [stale], now: now).isEmpty)
        XCTAssertTrue(AppleSiliconTemperatureService.detailedTemperatures(from: [], now: now).isEmpty)
        // Model/history layer: an already recorded legal 0 °C is a value, not "missing".
        let zeroDetail = SystemTemperatureDetailReading(id: "fixture.zero", name: "处理器芯片 1", zone: .chip, celsius: 0)
        let snapshot = SystemMonitorSnapshot(generatedAt: now, metrics: [], networkThroughput: nil,
            temperatureReadings: [.init(zone: .chip, celsius: 0)], temperatureDetails: [zeroDetail])
        XCTAssertEqual(snapshot.temperatureDetails?.first?.celsius, 0)
        XCTAssertEqual(snapshot.temperatureReadings?.first?.celsius, 0)
    }

    func testStableOrderingAndBoundedSelectionPreferRecognizedLocations() {
        let readings = (1...30).map { index in reading(index <= 20 ? "CPU tdie" : "unknown",
            service: "service-\(index)", ordinal: index, value: 10 + Double(index)) }
        let forward = AppleSiliconTemperatureService.detailedTemperatures(from: readings, now: now)
        let reversed = AppleSiliconTemperatureService.detailedTemperatures(from: readings.reversed(), now: now)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.count, 23)
        XCTAssertEqual(forward.filter { $0.channel?.confidence == .recognized }.count, 20)
        XCTAssertEqual(forward.filter { $0.channel?.confidence == .unknown }.count, 3)
    }

    func testCurrentHIDGraphKeepsIdentityAcrossOrderChangesAndDropsMissingEvents() throws {
        let driver = IdentityHIDDriver()
        let cache = HIDTemperatureMetadataCache(driver: driver)
        driver.graph = [1, 2]; driver.values = [1: 10, 2: 80]
        let first = try XCTUnwrap(cache.readings(now: now))
        driver.graph = [2, 1]; driver.values = [1: 12, 2: 70]
        let second = try XCTUnwrap(cache.readings(now: now.addingTimeInterval(5)))
        let before = AppleSiliconTemperatureService.detailedTemperatures(from: first, now: now)
        let after = AppleSiliconTemperatureService.detailedTemperatures(from: second, now: now.addingTimeInterval(5))
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(after.map(\.celsius), [12, 70])
        driver.values = [2: 70]
        XCTAssertEqual(try XCTUnwrap(cache.readings(now: now)).map(\.ordinal), [2])
        driver.graph = [2, 3]; driver.values = [2: 70, 3: 20]
        let third = try XCTUnwrap(cache.readings(now: now))
        XCTAssertEqual(third.map(\.ordinal), [2, 3])
        XCTAssertNotEqual(third.last?.serviceID, first.first?.serviceID)
    }

    func testSMCTopologyKeepsItsRowsAndOnePMUSummaryWithoutIndependentHIDRows() throws {
        let smc = (1...23).map { index in SystemTemperatureDetailReading(id: "smc.key\(index)",
            name: "CPU \(index)", zone: .chip, celsius: 30) }
        let hid = [AppleSiliconTemperatureService.Reading(name: "CPU tdie", value: 40, serviceID: "key1", ordinal: 1)]
        let combined = SystemMonitorService.detailedTemperatures(smcDetails: smc, smcPowerManagementCelsius: nil, hidReadings: hid)
        XCTAssertEqual(combined.map(\.id), smc.map(\.id))
        XCTAssertTrue(combined.allSatisfy { $0.channel?.source == .smc })
        let small = SystemMonitorService.detailedTemperatures(smcDetails: Array(smc.prefix(1)), smcPowerManagementCelsius: nil, hidReadings: hid)
        XCTAssertEqual(small.map(\.id), ["smc.key1"])
    }

    /// Shape of round2 probe `hid_idle1.tsv` (M5, SMC topology present): 42
    /// `PMU tdie1…14` services, `PMU tcal` ×3, `gas gauge battery` ×6,
    /// `NAND CH0 temp`, and `PMU tdev*` rows whose events were not plausible.
    func testProbeShapedHIDGraphWithSMCTopologyKeepsRowCountAndPMUSummary() throws {
        let smc = (1...20).map { index in SystemTemperatureDetailReading(id: "smc.T\(index)",
            name: "性能核心 \(index)", zone: .performanceCores, celsius: 60 + Double(index)) }
        var hid: [AppleSiliconTemperatureService.Reading] = []
        var ordinal = 0
        func add(_ name: String, _ value: Double) {
            ordinal += 1
            // No source time: the composition below runs at the real clock.
            hid.append(.init(name: name, value: value, serviceID: "\(4_294_970_000 + ordinal)", ordinal: ordinal))
        }
        for round in 0..<3 {
            for die in 1...14 { add("PMU tdie\(die)", 80 + Double(die) * 0.5 + Double(round) * 0.1) }
            add("PMU tcal", 51.82)
            add("gas gauge battery", 36.0); add("gas gauge battery", 36.7)
        }
        add("NAND CH0 temp", 50)
        let expectedPMU = try XCTUnwrap(hid.filter { $0.name.hasPrefix("PMU tdie") }.map(\.value).max())
        let details = SystemMonitorService.detailedTemperatures(smcDetails: smc, smcPowerManagementCelsius: 70, hidReadings: hid)
        XCTAssertEqual(details.count, smc.count + 1, "SMC rows + the single D57 PMU summary")
        XCTAssertEqual(Array(details.prefix(smc.count)).map(\.id), smc.map(\.id))
        let pmu = try XCTUnwrap(details.last)
        XCTAssertEqual(pmu.id, SystemTemperatureDetailReading.powerManagementID)
        XCTAssertEqual(pmu.name, SystemTemperatureDetailReading.powerManagement(celsius: 1).name)
        XCTAssertEqual(pmu.celsius, expectedPMU)
        XCTAssertFalse(details.contains { $0.zone == .battery || $0.zone == .storage })
        XCTAssertEqual(details.filter { $0.channel?.source == .hid }.count, 1)
        // Without the topology the HID graph is the inspector, bounded to 23 rows.
        let hidOnly = SystemMonitorService.detailedTemperatures(smcDetails: [], smcPowerManagementCelsius: nil, hidReadings: hid)
        XCTAssertEqual(hidOnly.count, 23)
        XCTAssertFalse(hidOnly.contains { $0.channel?.rawName == "PMU tcal" })
    }

    /// Real Apple Silicon HID product labels (round2 research §五, M1–M4):
    /// "<block> MTR Temp Sensor<N>"; the synthetic "… MTR Temp <N>" form stays valid.
    func testRealHIDMTRSensorLabelsMapToTheirRegions() throws {
        let labels: [(String, SystemTemperatureZone?)] = [
            ("pACC MTR Temp Sensor0", .performanceCores), ("pACC MTR Temp Sensor9", .performanceCores),
            ("eACC MTR Temp Sensor1", .efficiencyCores), ("GPU MTR Temp Sensor4", .gpu),
            ("SOC MTR Temp Sensor0", .soc), ("SOC MTR Temp Sensor2", .soc),
            ("pACC MTR Temp 0", .performanceCores), ("GPU MTR Temp 1", .gpu),
            ("ANE MTR Temp Sensor1", nil), ("ISP MTR Temp Sensor5", nil),
            ("NAND CH0 temp", .storage), ("gas gauge battery", .battery),
        ]
        let readings = labels.enumerated().map { index, label in
            reading(label.0, service: "r\(index)", ordinal: index + 1, value: 40 + Double(index)) }
        let details = AppleSiliconTemperatureService.detailedTemperatures(from: readings, now: now)
        for (index, label) in labels.enumerated() {
            let detail = try XCTUnwrap(details.first { $0.channel?.rawName == label.0 }, label.0)
            XCTAssertEqual(detail.zone, label.1, label.0)
            XCTAssertEqual(detail.celsius, 40 + Double(index), label.0)
        }
        let regional = AppleSiliconTemperatureService.regionalTemperatures(from: readings, now: now)
        XCTAssertEqual(Set(regional.map(\.zone)), [.performanceCores, .efficiencyCores, .gpu, .soc, .storage, .battery])
        XCTAssertEqual(regional.first { $0.zone == .performanceCores }?.celsius, 46)
        // SoC monitors take precedence for the chip summary (hottest SoC sensor).
        XCTAssertEqual(AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings, now: now), 45)
        // PMU2 dies are PMU, never CPU; PMU2 tcal is calibration and hidden.
        let pmu2 = [reading("PMU2 tdie3", service: "p", ordinal: 1, value: 77),
                    reading("PMU2 tcal", service: "c", ordinal: 2, value: 51.8)]
        let pmuDetails = AppleSiliconTemperatureService.detailedTemperatures(from: pmu2, now: now)
        XCTAssertEqual(pmuDetails.map(\.celsius), [77])
        XCTAssertNil(pmuDetails.first?.zone)
        XCTAssertNil(AppleSiliconTemperatureService.chipTemperatureCelsius(from: pmu2, now: now))
        XCTAssertEqual(AppleSiliconTemperatureService.powerManagementTemperatureCelsius(from: pmu2, now: now), 77)
    }

    func testDisplayNumbersFollowRawLabelThenKeyNotCacheOrdinal() {
        let readings = [reading("PMU tdie10", service: "a", ordinal: 1, value: 50),
                        reading("PMU tdie2", service: "b", ordinal: 9, value: 51),
                        reading("PMU tdie1", service: "c", ordinal: 5, value: 52)]
        let names = Dictionary(uniqueKeysWithValues: AppleSiliconTemperatureService
            .detailedTemperatures(from: readings, now: now).map { ($0.channel!.rawName, $0.name) })
        XCTAssertTrue(names["PMU tdie1"]!.hasSuffix(" 1"))
        XCTAssertTrue(names["PMU tdie2"]!.hasSuffix(" 2"))
        XCTAssertTrue(names["PMU tdie10"]!.hasSuffix(" 3"))
    }

    func testSMCCompositeRowsDiscloseTheirActualKeysAndAverageMeaning() {
        let gpu = SystemTemperatureDetailReading(id: "smc.gpu-region-1", name: "GPU 区域 1 均值", zone: .gpu, celsius: 30)
        let details = SystemMonitorService.detailedTemperatures(smcDetails: [gpu], smcPowerManagementCelsius: 40, hidReadings: [])
        XCTAssertTrue(details.first?.sourceHelp.contains("Tg08") == true)
        XCTAssertTrue(details.first?.sourceHelp.contains("均值") == true)
        let pmu = details.first { $0.id == SystemTemperatureDetailReading.powerManagementID }
        XCTAssertTrue(pmu?.sourceHelp.contains("TPDX,TRDX,TUDX") == true)
    }

    private func reading(_ name: String, service: String, ordinal: Int, value: Double) -> AppleSiliconTemperatureService.Reading {
        .init(name: name, value: value, serviceID: service, ordinal: ordinal, sampledAt: now)
    }
}

// Dynamic fake events are never cached. Visible in Debug and Release tests.
private final class IdentityHIDDriver: HIDTemperatureReadingDriver {
    var graph: [Int] = []
    var values: [Int: Double] = [:]
    func services() -> [Int]? { graph }
    func identity(of service: Int) -> Int { service }
    func rawIdentifier(of service: Int) -> String? { "service-\(service)" }
    func name(of service: Int) -> String? { "CPU tdie" }
    func temperature(of service: Int) -> Double? { values[service] }
}
