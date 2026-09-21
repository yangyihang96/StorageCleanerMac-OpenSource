import XCTest
@testable import StorageCleanerMac

final class MemoryRunningApplicationIndexTests: XCTestCase {
    private func identity(_ name: String, launch: TimeInterval?) -> SystemMemoryProbe.RunningAppIdentity {
        .init(name: name, bundleIdentifier: "example.\(name)", bundlePath: nil,
              executablePath: "/\(name)", launchDate: launch.map(Date.init(timeIntervalSince1970:)),
              activationPolicy: .regular, isActive: false)
    }

    func testRepeatedPIDsKeepNewestCompleteIdentityRegardlessOfOrder() {
        let old = identity("old", launch: 10)
        let new = identity("new", launch: 20)
        for entries in [[(Int32(42), old), (Int32(42), new)], [(Int32(42), new), (Int32(42), old)]] {
            let result = SystemMemoryProbe.indexRunningApplications(entries)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[42]?.name, "new")
            XCTAssertEqual(result[42]?.executablePath, "/new")
        }
    }

    func testInvalidPIDsAndUnknownLaunchDatesDoNotTrapOrReplaceKnownIdentity() {
        let known = identity("known", launch: 20)
        let unknown = identity("unknown", launch: nil)
        let result = SystemMemoryProbe.indexRunningApplications([
            (-1, unknown), (-1, known), (0, unknown), (42, known), (42, unknown),
            (43, unknown), (43, known), (44, unknown), (44, unknown)
        ])
        XCTAssertEqual(Set(result.keys), [42, 43, 44])
        XCTAssertEqual(result[42]?.name, "known")
        XCTAssertEqual(result[43]?.name, "known")
        XCTAssertEqual(result[44]?.name, "unknown")
    }
}
