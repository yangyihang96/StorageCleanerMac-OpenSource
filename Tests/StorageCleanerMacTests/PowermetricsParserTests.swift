import FanControlShared
import Foundation
import XCTest

final class PowermetricsParserTests: XCTestCase {
    func testModernAndUltraClusterIdentityIsPreservedWithoutMappingMCPUToEfficiency() throws {
        let names = ["PCPU", "MCPU0", "MCPU1", "ECPU", "DIE_0_PCPU", "DIE_1_MCPU0", "DIE_1 ECPU", "DIE_0_P0"]
        let sample = try parse(["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 5_000,
            "clusters": names.map { ["name": $0, "freq_mhz": 3_000] }]])
        XCTAssertEqual(sample.clusters.map(\.name), names)
        XCTAssertEqual(sample.clusters.map(\.kind), [.performance, .performance, .performance, .efficiency,
                                                     .performance, .performance, .efficiency, .performance])
        XCTAssertTrue(sample.isValid)
        XCTAssertEqual(try JSONDecoder().decode(PowermetricsSample.self, from: JSONEncoder().encode(sample)), sample)
        let invalid = try parse(["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 5_000,
            "clusters": ["DIE_X_PCPU", "DIE__ECPU", "DIE_0PCPU", "MCPU0_0", "MCPU0;sh"].map {
                ["name": $0, "freq_mhz": 3_000]
            }]])
        XCTAssertTrue(invalid.clusters.isEmpty)
    }

    func testElapsedDurationAndUnverifiedTimestampKeysDoNotCreateTimingEvidence() throws {
        let sample = try parse(["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 5_000],
            "timestamp": 100, "measurementStartMonotonicNs": 100_000_000_000,
            "measurementEndMonotonicNs": 101_000_000_000])
        XCTAssertEqual(sample.durationSeconds, 1)
        XCTAssertNil(sample.timing, "unknown native timestamp fields are not verified measurement evidence")
    }

    /// Contract fixtures, not claimed recordings of these machines. Native
    /// M1 energy/Hz, multi-cluster Ultra, and newer direct-power variants.
    func testModelShapeFixturesKeepUnitsAndMultipleClusters() throws {
        let m1 = try parse([
            "elapsed_ns": 1_000_000_000,
            "processor": ["cpu_energy": 2_500, "gpu_energy": 300, "ane_energy": 0,
                          "clusters": [["name": "E0", "freq_hz": 1_200_000_000],
                                       ["name": "P0", "freq_hz": 3_200_000_000]]],
            "gpu": ["freq_hz": 800],
        ])
        XCTAssertEqual(m1.cpuMilliwatts, 2_500)
        XCTAssertEqual(m1.gpuMilliwatts, 300)
        XCTAssertEqual(m1.aneMilliwatts, 0, "measured zero differs from missing")
        XCTAssertEqual(m1.clusters.map(\.megahertz), [1_200, 3_200])
        XCTAssertEqual(m1.gpuMegahertz, 800, "the native GPU plist uses MHz despite its key name")
        XCTAssertEqual(m1.durationSeconds, 1)

        let ultra = try parse([
            "elapsed_ns": 2_000_000_000,
            "processor": ["cpu_energy": 60_000, "gpu_energy": 16_000,
                          "clusters": [["name": "P0", "freq_hz": 3_000_000_000],
                                       ["name": "P1", "freq_hz": 3_100_000_000],
                                       ["name": "E0", "freq_hz": 1_000_000_000],
                                       ["name": "E1", "freq_hz": 900_000_000]]],
            "gpu": ["freq_hz": 900_000_000],
        ])
        XCTAssertEqual(ultra.cpuMilliwatts, 30_000, "energy is divided by the actual interval")
        XCTAssertEqual(ultra.gpuMilliwatts, 8_000)
        XCTAssertNil(ultra.aneMilliwatts)
        XCTAssertEqual(ultra.clusters.count, 4)
        XCTAssertEqual(ultra.gpuMegahertz, 900)

        let modern = try parse([
            "elapsed_ns": 1_100_000_000,
            "processor": ["cpu_power": 8_234.5, "gpu_power": 4_002.5, "ane_power": 10,
                          "clusters": [["name": "P0", "freq_mhz": 4_100],
                                       ["name": "E0", "freq_mhz": 1_600]]],
            "gpu": ["freq_mhz": 1_200],
        ])
        XCTAssertEqual(modern.cpuMilliwatts, 8_234.5, "power is already an interval average")
        XCTAssertEqual(modern.durationSeconds, 1.1)
        XCTAssertEqual(modern.gpuMegahertz, 1_200)
    }

    func testExplicitPowerAndEnergyUnitsAreConvertedOrRejected() throws {
        for (unit, raw) in [("mJ", 1_000.0), ("J", 1.0), ("uJ", 1_000_000.0), ("µJ", 1_000_000.0)] {
            let sample = try parse(["elapsed_ns": 500_000_000,
                "processor": ["cpu_energy": raw, "energy_unit": unit]])
            XCTAssertEqual(sample.cpuMilliwatts, 2_000, unit)
        }
        let watts = try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": 2.75, "power_unit": "W"]])
        XCTAssertEqual(watts.cpuMilliwatts, 2_750)
        XCTAssertThrowsError(try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": 2.75, "power_unit": "kW"]]))
        XCTAssertThrowsError(try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_energy": 2, "energy_unit": "unknown"]]))
    }

    func testMissingFieldsStayNilAndUnrelatedPrivateFieldsDoNotEscape() throws {
        let sample = try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": 0], "tasks": [["pid": 123, "name": "PRIVATE_PROCESS"]],
            "machine_model": "PRIVATE_MACHINE", "gpu": ["unused": 17]])
        XCTAssertEqual(sample.cpuMilliwatts, 0)
        XCTAssertNil(sample.gpuMilliwatts)
        XCTAssertNil(sample.aneMilliwatts)
        XCTAssertNil(sample.gpuMegahertz)
        let json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        for forbidden in ["PRIVATE", "tasks", "pid", "machine_model", "unused"] { XCTAssertFalse(json.contains(forbidden)) }
        XCTAssertEqual(try JSONDecoder().decode(PowermetricsSample.self, from: JSONEncoder().encode(sample)), sample)
    }

    func testInvalidNumbersAndUnknownFrequencyUnitsAreNeverZeroFilled() throws {
        let sample = try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": -1, "gpu_power": 0, "ane_power": true,
                "clusters": [["name": "P0", "freq_hz": 3_000, "frequency_unit": "kHz"],
                             ["name": "PRIVATE_NAME", "freq_mhz": 2_000]]],
            "gpu": ["freq_hz": 15_000]])
        XCTAssertNil(sample.cpuMilliwatts)
        XCTAssertNil(sample.aneMilliwatts)
        XCTAssertEqual(sample.gpuMilliwatts, 0)
        XCTAssertTrue(sample.clusters.isEmpty)
        XCTAssertNil(sample.gpuMegahertz, "ambiguous unit range is refused")
        for value in [-1.0, 0, 10_000_000_000, Double.nan] {
            XCTAssertThrowsError(try parse(["elapsed_ns": value, "processor": ["cpu_power": 5]]))
        }
        XCTAssertThrowsError(try parse(["elapsed_ns": true, "processor": ["cpu_power": 5]]))
        XCTAssertThrowsError(try parse(["processor": ["cpu_power": 5]]))
        XCTAssertThrowsError(try parse(["elapsed_ns": 1_000_000_000]))
    }

    func testFramingIsOneNULTerminatedPlistAndBounded() throws {
        let data = try PropertyListSerialization.data(fromPropertyList:
            ["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 10]], format: .xml, options: 0)
        XCTAssertEqual(try PowermetricsPlistParser.parse(data + Data([0])).cpuMilliwatts, 10)
        XCTAssertThrowsError(try PowermetricsPlistParser.parse(data + Data([0]) + data))
        XCTAssertThrowsError(try PowermetricsPlistParser.parse(Data("CPU Power: 10 mW".utf8)))
        XCTAssertThrowsError(try PowermetricsPlistParser.parse(Data()))
        XCTAssertThrowsError(try PowermetricsPlistParser.parse(Data(repeating: 32, count: 512 * 1_024 + 1)))
    }

    func testTooManyOrDuplicateClustersAreRejected() throws {
        XCTAssertThrowsError(try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": 5, "clusters": (0..<17).map { ["name": "P\($0)", "freq_mhz": 3_000] }]]))
        XCTAssertThrowsError(try parse(["elapsed_ns": 1_000_000_000,
            "processor": ["cpu_power": 5, "clusters": [["name": "P0", "freq_mhz": 3_000], ["name": "P0", "freq_mhz": 3_100]]]]))
    }

    private func parse(_ plist: [String: Any]) throws -> PowermetricsSample {
        try PowermetricsPlistParser.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }
}
