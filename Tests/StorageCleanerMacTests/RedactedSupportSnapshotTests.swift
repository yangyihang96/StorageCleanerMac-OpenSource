import XCTest
@testable import StorageCleanerMac

final class RedactedSupportSnapshotTests: XCTestCase {
    func testPrivateStringsCannotEnterExportAndPreviewBytesAreDeterministic() throws {
        let runtime = AppRuntimeInfo(kind: .other, path: "/Users/private-person/secret",
            bundleIdentifier: "private-person.token", version: "/Users/private-person",
            build: "192.0.2.1", buildInfo: nil)
        let snapshot = RedactedSupportSnapshot(runtime: runtime,
            systemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0), reports: [])
        let data = try snapshot.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for privateValue in ["private-person", "/Users", "192.0.2.1", "secret", "token"] {
            XCTAssertFalse(text.contains(privateValue))
        }
        XCTAssertNil(snapshot.appVersion)
        XCTAssertNil(snapshot.appBuild)
        XCTAssertEqual(data, try snapshot.encoded())
        XCTAssertEqual(try JSONDecoder().decode(RedactedSupportSnapshot.self, from: data), snapshot)
    }

    func testOnlyBoundedStatusCountsAreExportedNotReportIdentityOrPaths() throws {
        let fixture = try RecordedCleanupRecoveryTests.Fixture(); defer { fixture.remove() }
        let report = fixture.report
        let index = CleanupReportIndex(report: report, orderingDate: Date())
        let runtime = AppRuntimeInfo(kind: .applications, path: "/Applications/测试版.app",
            bundleIdentifier: "com.local.StorageCleanerMac.beta", version: "2.0.0",
            build: "20260928092533", buildInfo: .init(version: "2.0.0", build: "20260928092533",
                commit: "private-secret", dirty: true, buildDate: "private-date", configuration: "Beta"))
        let snapshot = RedactedSupportSnapshot(runtime: runtime,
            systemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0),
            reports: Array(repeating: index, count: 150))
        XCTAssertEqual(snapshot.loadedOperationCount, 100)
        XCTAssertEqual(snapshot.operationStates, ["completed": 100])
        XCTAssertEqual(snapshot.channel, "beta")
        XCTAssertEqual(snapshot.appVersion, "2.0.0")
        let text = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for value in [report.id.uuidString, report.planID.rawValue.uuidString,
                      report.items[0].sourcePath, "private-secret", "private-date", runtime.path] {
            XCTAssertFalse(text.contains(value))
        }
    }
}
