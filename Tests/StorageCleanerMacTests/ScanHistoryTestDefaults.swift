import Foundation
import XCTest
@testable import StorageCleanerMac

/// r2-live-fixes-2 review P2-1: the scan history a store under test writes
/// goes to a private suite that is removed when the test ends. A completed
/// scan (the Smart Scan since N20, the old full-disk scan before it) records
/// into `ScanStore`'s `scanHistoryDefaults`, which is `UserDefaults.standard`
/// unless a test passes one: the test process's own domain
/// ("com.apple.dt.xctest.tool"), which persists from run to run.
///
/// Every store fixture that can complete a scan takes its defaults from
/// here. The teardown also checks that the test left the standard domain's
/// `scan.history` as it found it, so a fixture that forgets to pass the
/// suite fails instead of writing there.
enum ScanHistoryTestDefaults {
    static func make(
        for testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserDefaults {
        defaults(named: makeSuite(for: testCase, file: file, line: line))
    }

    /// The suite's name, for a fixture that builds its store on the main
    /// actor (a name crosses isolation; a `UserDefaults` does not).
    static func makeSuite(
        for testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let name = TestPreferenceDomain.makeSuite(file: file)
        let standardBefore = standardHistory()
        testCase.addTeardownBlock {
            TestPreferenceDomain.cleanup(suiteName: name, file: file, line: line)
            XCTAssertEqual(
                standardHistory(),
                standardBefore,
                "The test wrote scan history to UserDefaults.standard",
                file: file,
                line: line
            )
        }
        return name
    }

    static func defaults(named name: String) -> UserDefaults {
        guard let defaults = TestPreferenceDomain.open(suiteName: name) else {
            preconditionFailure("临时绝对路径是有效的测试偏好域")
        }
        return defaults
    }

    /// The standard domain's scan history, exactly as stored.
    static func standardHistory() -> Data? {
        UserDefaults.standard.data(forKey: ScanHistoryService.defaultsKey)
    }
}
