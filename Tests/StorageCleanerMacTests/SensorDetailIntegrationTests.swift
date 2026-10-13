import XCTest
@testable import StorageCleanerMac

final class SensorDetailIntegrationTests: XCTestCase {
    func testHIDDetailsKeepFiniteChannelsWithConservativeUnknownNames() {
        let readings = [
            AppleSiliconTemperatureService.Reading(name: "pACC MTR Temp 0", value: 53),
            AppleSiliconTemperatureService.Reading(name: "pACC MTR Temp 0", value: 54),
            AppleSiliconTemperatureService.Reading(name: "GPU MTR Temp 0", value: 61),
            AppleSiliconTemperatureService.Reading(name: "unmapped probe", value: 58),
            AppleSiliconTemperatureService.Reading(name: "battery", value: .infinity),
            AppleSiliconTemperatureService.Reading(name: "", value: 45)
        ]

        let details = AppleSiliconTemperatureService.detailedTemperatures(from: readings)
        // D81: equal labels are two channels; unnamed/unmapped valid probes remain conservative.
        XCTAssertEqual(details.count, 5)
        XCTAssertEqual(details.filter { $0.zone == .performanceCores }.map(\.celsius).sorted(), [53, 54])
        XCTAssertEqual(details.filter { $0.channel?.confidence == .unknown }.count, 2)
        XCTAssertEqual(Set(details.map(\.id)).count, 5)
        XCTAssertEqual(details.first { $0.zone == .gpu }?.celsius, 61)
    }

    func testSMCDetailsRequireCompleteKnownTopology() {
        XCTAssertTrue(SMCFanSpeedService.detailedTemperatureReadings { key in
            key == "Tp00" ? 55 : nil
        }.isEmpty)

        let superKeys = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
        let performanceKeys = [
            "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
            "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
        ]
        var values = Dictionary(uniqueKeysWithValues:
            (superKeys + performanceKeys).enumerated().map { ($0.element, Double(50 + $0.offset)) }
        )
        values["Tg08"] = 64
        values["Tg2P"] = 70
        let details = SMCFanSpeedService.detailedTemperatureReadings {
            values[$0]
        }
        XCTAssertEqual(details.count, 20)
        XCTAssertEqual(Set(details.map(\.id)).count, details.count)
        XCTAssertEqual(details.filter { $0.zone == .superCores }.count, 6)
        XCTAssertEqual(details.filter { $0.zone == .performanceCores }.count, 12)
        XCTAssertEqual(details.filter { $0.zone == .gpu }.map(\.celsius), [64, 70])
    }

    func testDetailedTemperatureFollowsTheExistingSnapshotWithoutEnteringHistory() {
        let detail = SystemTemperatureDetailReading(
            id: "hid.gpu mtr temp 0", name: "GPU MTR Temp 0", zone: .gpu, celsius: 55
        )
        let thermal = SystemMonitorService.ThermalReadings(
            gpuUsagePercent: nil, chipTemperatureCelsius: nil,
            fanSpeedRPM: nil, fanCount: nil, temperatureDetails: [detail]
        )
        let snapshot = SystemMonitorService.buildSnapshot(
            enabledKinds: [.chipTemperature], memorySnapshot: nil,
            previousNetworkSample: nil,
            liveReadings: .init(cpuUsagePercent: nil, thermal: thermal, networkSample: nil),
            now: Date()
        ).snapshot
        XCTAssertEqual(snapshot.temperatureDetails, [detail])
        let historical = MenuBarTelemetryPoint(snapshot: snapshot)
        XCTAssertNil(historical.temperatureReadings)
    }

    func testSnapshotRejectsDuplicateOrImplausibleDetailReadings() {
        let detail = SystemTemperatureDetailReading(
            id: "smc.Tp00", name: "Core 1", zone: .performanceCores, celsius: 52
        )
        let duplicate = SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil,
            temperatureDetails: [detail, detail]
        )
        XCTAssertNil(duplicate.temperatureDetails)
        let invalid = SystemMonitorSnapshot(
            generatedAt: Date(), metrics: [], networkThroughput: nil,
            temperatureDetails: [.init(id: "smc.Tp00", name: "Core 1", zone: .performanceCores, celsius: 300)]
        )
        XCTAssertNil(invalid.temperatureDetails)
    }
}
