import Foundation
import XCTest
@testable import StorageCleanerMac

final class OfficialWebsiteSearchServiceTests: XCTestCase {
    func testCandidateSearchUsesIdentityEvidenceWithoutLocalPath() throws {
        let application = AppUpdateTestFixtures.application(
            name: "Example Utility",
            bundleIdentifier: "com.example.utility",
            path: "/Users/private-name/Applications/Example Utility.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.utility"
        )

        let candidate = try OfficialWebsiteSearchService().candidateSearch(for: application)
        let components = try XCTUnwrap(URLComponents(
            url: candidate.searchURL,
            resolvingAgainstBaseURL: false
        ))
        let query = try XCTUnwrap(components.queryItems?.first { $0.name == "q" }?.value)

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/search")
        XCTAssertTrue(query.contains("Example Utility"))
        XCTAssertTrue(query.contains("com.example.utility"))
        XCTAssertTrue(query.contains("TEAM123"))
        XCTAssertTrue(query.contains("official"))
        XCTAssertTrue(query.contains("download"))
        XCTAssertFalse(query.contains("private-name"))
        XCTAssertEqual(candidate.trustLevel, .candidate)
    }

    func testCandidateSearchDoesNotPromoteSearchResultsToTrustedSource() throws {
        let candidate = try OfficialWebsiteSearchService().candidateSearch(
            for: AppUpdateTestFixtures.application()
        )

        XCTAssertLessThan(candidate.trustLevel, .userConfirmed)
        XCTAssertEqual(candidate.trustLevel, .candidate)
    }
}
