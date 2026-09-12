import Foundation
import XCTest

@testable import StorageCleanerMac

final class BenchmarkV7HardwareProfileTests: XCTestCase {
    func testSystemProfilerFixtureKeepsStableFieldsAndIgnoresUniqueIdentifiers() throws {
        let fixture = """
        {
          "SPHardwareDataType": [{
            "machine_name": "MacBook Pro",
            "machine_model": "Mac17,9",
            "serial_number": "MUST NOT PERSIST"
          }],
          "SPDisplaysDataType": [{ "sppci_cores": "20" }],
          "SPNVMeDataType": [{
            "_items": [{
              "device_model": "APPLE SSD AP1024Z",
              "bsd_name": "disk0"
            }]
          }]
        }
        """
        let profile = try XCTUnwrap(
            BenchmarkV7HardwareProfileCollector.parseSystemProfilerJSON(
                Data(fixture.utf8),
                computerName: "测试 Mac"
            )
        )

        XCTAssertEqual(profile.computerName, "测试 Mac")
        XCTAssertEqual(profile.computerModel, "MacBook Pro")
        XCTAssertEqual(profile.modelIdentifier, "Mac17,9")
        XCTAssertEqual(profile.gpuCoreCount, 20)
        XCTAssertEqual(profile.storageModel, "APPLE SSD AP1024Z")
    }

    func testEarlyV7JSONWithoutHardwareProfileDecodesAsNil() throws {
        let plan = BenchmarkV7Plan.quick
        let storage = BenchmarkV7StorageTarget(
            volumeName: "Fixture",
            fileSystem: "APFS",
            availableBytes: 1_000,
            isReadOnly: false
        )
        let preflight = BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            backgroundLoadRatio: 0,
            availableMemoryBytes: 1_000,
            storageTarget: storage,
            displayDescription: "Fixture display",
            checks: [],
            blockedCategories: []
        )
        let result = BenchmarkV7Result(
            session: BenchmarkV7Session(plan: plan, storageTarget: storage),
            preflight: preflight,
            versions: BenchmarkV7VersionManifest(
                planVersion: plan.planVersion,
                workloadVersion: plan.workloadVersion,
                statisticsVersion: "fixture",
                scoringVersion: "fixture",
                referenceSetVersion: "fixture"
            ),
            metrics: [],
            coreScore: nil,
            completedAt: nil,
            failure: .cancelled
        )
        let encoded = try JSONEncoder().encode(result)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "hardwareProfile")
        let legacy = try JSONDecoder().decode(
            BenchmarkV7Result.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.hardwareProfile)
        XCTAssertEqual(legacy.failure, .cancelled)
    }

    func testProviderCanBeInjectedWithoutInventingMissingValues() {
        let fixture = BenchmarkV7HardwareProfile(
            computerName: "Studio",
            computerModel: "Mac mini",
            modelIdentifier: "Mac14,3",
            gpuCoreCount: 10
        )
        let provider: any BenchmarkV7HardwareProfileProviding = FixtureHardwareProvider(
            profile: fixture
        )
        XCTAssertEqual(provider.capture(), fixture)
        XCTAssertNil(provider.capture()?.storageModel)
    }
}

private struct FixtureHardwareProvider: BenchmarkV7HardwareProfileProviding {
    let profile: BenchmarkV7HardwareProfile

    func capture() -> BenchmarkV7HardwareProfile? { profile }
}
