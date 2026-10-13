import Foundation
import XCTest
@testable import StorageCleanerMac

/// r2-live-fixes-1 review P2-5: a browser counts as the real one for direct
/// deletion only when it is signed by that browser's own Team ID, not by
/// any Apple-issued certificate with any Team ID (D42 checks the chain).
/// Google Chrome is pinned to EQHXZ8M8AV (read-only `codesign -dv` of the
/// installed Chrome on this Mac, 2026-10-07). Browsers not installed here
/// keep the previous rule until their Team ID is verified the same way.
final class BrowserPrivacyTeamIdentifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserPrivacyTeamIdentifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testChromeIsPinnedToGooglesTeamIdentifier() throws {
        let chrome = try XCTUnwrap(BrowserPrivacyProviderRegistry.defaultProviders
            .first { $0.descriptor.id == "chrome" }?.descriptor)
        XCTAssertEqual(chrome.teamIdentifiers["com.google.Chrome"], "EQHXZ8M8AV")
        // Not installed on the Mac this was verified on: unchanged.
        XCTAssertNil(chrome.teamIdentifiers["com.google.Chrome.beta"])
        XCTAssertNil(chrome.teamIdentifiers["com.google.Chrome.canary"])
        for other in BrowserPrivacyProviderRegistry.defaultProviders where other.descriptor.id != "chrome" {
            XCTAssertTrue(other.descriptor.teamIdentifiers.isEmpty, "\(other.descriptor.id) is not verified here")
        }
    }

    func testAChromeSignedByAnotherTeamIsNotTheRealChrome() throws {
        let chrome = try XCTUnwrap(BrowserPrivacyProviderRegistry.defaultProviders
            .first { $0.descriptor.id == "chrome" }?.descriptor)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let profileRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let database = profileRoot.appendingPathComponent("Default/History")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let application = try makeApplication(bundleIdentifier: "com.google.Chrome")

        func writeRoot(team: String?) -> URL? {
            let browser = BrowserPrivacyBrowser(
                id: "chrome", displayName: "Google Chrome", engine: .chromium,
                bundleIdentifier: "com.google.Chrome", version: "150.0", applicationURL: application,
                signingIdentity: StartupApplicationSigningIdentity(
                    teamIdentifier: team, codeSigningIdentifier: "com.google.Chrome",
                    designatedRequirement: "anchor apple generic and identifier \"com.google.Chrome\""))
            return chrome.productionWriteRoot(browser: browser, homeDirectory: home, databaseURL: database)
        }

        XCTAssertEqual(writeRoot(team: "EQHXZ8M8AV")?.standardizedFileURL, profileRoot.standardizedFileURL)
        XCTAssertNil(writeRoot(team: "ABCDE12345"), "another developer's app with Chrome's identifier")
        XCTAssertNil(writeRoot(team: nil))
    }

    /// Review P2-11: the Chrome provider also lists the Beta and Canary
    /// bundle identifiers, which have no pinned Team ID (not installed where
    /// this was verified), and only the stable profile root. The stable root
    /// is now bound to the stable app: a Beta or Canary identifier, with any
    /// Team ID, cannot write it (their own profiles live in "Chrome Beta" and
    /// "Chrome Canary", which are not registered).
    func testTheStableChromeProfileIsWrittenOnlyByTheStableApp() throws {
        let chrome = try XCTUnwrap(BrowserPrivacyProviderRegistry.defaultProviders
            .first { $0.descriptor.id == "chrome" }?.descriptor)
        XCTAssertEqual(chrome.rootBundleIdentifiers["Library/Application Support/Google/Chrome"],
                       ["com.google.Chrome"])
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let profileRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let database = profileRoot.appendingPathComponent("Default/History")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Each channel at its own path: Bundle(url:) caches by path.
        for (channel, name) in [("com.google.Chrome.beta", "Google Chrome Beta"),
                                ("com.google.Chrome.canary", "Google Chrome Canary")] {
            let application = try makeApplication(bundleIdentifier: channel, name: name)
            for team in ["ABCDE12345", "EQHXZ8M8AV"] {
                let browser = BrowserPrivacyBrowser(
                    id: "chrome", displayName: "Google Chrome", engine: .chromium,
                    bundleIdentifier: channel, version: "150.0", applicationURL: application,
                    signingIdentity: StartupApplicationSigningIdentity(
                        teamIdentifier: team, codeSigningIdentifier: channel,
                        designatedRequirement: "anchor apple generic and identifier \"\(channel)\""))
                XCTAssertNil(chrome.productionWriteRoot(browser: browser, homeDirectory: home, databaseURL: database),
                             "\(channel) signed by \(team) does not write the stable Chrome profile")
            }
        }
    }

    private func makeApplication(bundleIdentifier: String, name: String = "Google Chrome") throws -> URL {
        let application = root.appendingPathComponent("Applications/\(name).app", isDirectory: true)
        let executable = application.appendingPathComponent("Contents/MacOS/\(name)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleIdentifier, "CFBundleName": name,
            "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        try info.write(to: application.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: executable.path, contents: Data("fixture".utf8))
        return application
    }
}
