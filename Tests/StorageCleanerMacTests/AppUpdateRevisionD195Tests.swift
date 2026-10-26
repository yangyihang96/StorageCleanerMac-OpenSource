import XCTest
@testable import StorageCleanerMac

final class AppUpdateRevisionD195Tests: XCTestCase {
    func testHomebrewStableRevisionReachesTheAvailableVersionAndKeepsInstalledSuffix() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        for (installed, revision, expected) in [("4.0.0", 1, "4.0.0_1"), ("4.0.0_1", 2, "4.0.0_2")] {
            let fixture = Data("""
            {"formulae":[{"name":"ada-url","installed":[{"version":"\(installed)"}],
            "versions":{"stable":"4.0.0"},"revision":\(revision)}],"casks":[]}
            """.utf8)
            let packages = try HomebrewInventoryParser.parse(installedData: fixture,
                outdatedData: Data(#"{"formulae":[{"name":"ada-url"}],"casks":[]}"#.utf8), prefixURL: root)
            let metadata = try XCTUnwrap(packages.first?.metadata)
            XCTAssertEqual(metadata.installedVersions, [installed])
            XCTAssertEqual(metadata.currentVersion, expected)
            XCTAssertTrue(metadata.isOutdated)
            let url = root.appendingPathComponent("Cellar/ada-url/" + installed)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let installedApp = AppUpdateTestFixtures.application(id: "ada-url", path: url.path,
                version: try XCTUnwrap(metadata.installedVersions.last), build: "", installationSource: .homebrewFormula,
                provider: .homebrew, status: .discovered, sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: metadata)
            let app = await ApplicationUpdateProviderRegistry(providers: [HomebrewProvider(homebrewExecutableProvider: { nil })])
                .classify(installedApp)
            XCTAssertEqual(app.installedVersion.display + " → " + (app.availableVersion?.display ?? "—"), installed + " → " + expected)
            XCTAssertTrue(app.hasConfirmedPresentableUpdate, "D192 confirmation still includes revision-only updates")
        }
    }

    func testNoRevisionAndHeadKeepTheirExistingVersions() throws {
        let data = Data(#"{"formulae":[{"name":"zero","versions":{"stable":"1.0"},"revision":0},{"name":"missing","versions":{"stable":"2.0"}},{"name":"head","versions":{"stable":null,"head":"HEAD"},"revision":1}],"casks":[]}"#.utf8)
        let packages = try HomebrewInventoryParser.parse(installedData: data, outdatedData: nil,
            prefixURL: URL(fileURLWithPath: "/Fixture"))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: packages.map { ($0.metadata.token, $0.metadata.currentVersion) }),
                       ["zero": "1.0", "missing": "2.0", "head": "HEAD"])
    }
}
