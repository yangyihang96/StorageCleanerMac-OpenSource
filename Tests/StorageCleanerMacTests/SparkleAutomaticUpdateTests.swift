import FileOperationShared
import CryptoKit
import Foundation
import XCTest
@testable import StorageCleanerMac

final class SparkleAutomaticUpdateTests: XCTestCase {
    func testAppcastChoosesNewestCompatibleFullArchiveAndRejectsDTD() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/2.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        <item><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/3.zip" sparkle:version="300" sparkle:shortVersionString="3.0"/></item>
        <item><enclosure url="https://example.com/9.delta" sparkle:deltaFrom="100" sparkle:version="900"/></item>
        </channel></rss>
        """
        let release = try XCTUnwrap(SparkleAppcastParser.select(Data(xml.utf8), installed: .init(marketing: "1.0", build: "100"), systemVersion: "14.0"))
        XCTAssertEqual(release.version, .init(marketing: "2.0", build: "200"))
        XCTAssertEqual(release.downloadURL.pathExtension, "zip")
        XCTAssertThrowsError(try SparkleAppcastParser.select(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss/>".utf8), installed: .init(marketing: "1"), systemVersion: "14"))
    }

    func testEdDSAValidArchivePassesSharedIdentityVerificationAndReplaces() async throws {
        try await exerciseArchive(signatureValid: true, candidateTeam: "TEAM123", candidateVersion: "2.0", expectedSuccess: true)
    }
    func testInvalidEdDSASignatureNeverExtractsOrReplacesAndPreservesOldApp() async throws {
        try await exerciseArchive(signatureValid: false, candidateTeam: "TEAM123", candidateVersion: "2.0", expectedSuccess: false)
    }
    func testChangedTeamRejectsEvenValidEdDSAArchiveAndPreservesOldApp() async throws {
        try await exerciseArchive(signatureValid: true, candidateTeam: "OTHERTEAM", candidateVersion: "2.0", expectedSuccess: false)
    }
    func testNonNewerBundleRejectsEvenValidArchiveAndPreservesOldApp() async throws {
        try await exerciseArchive(signatureValid: true, candidateTeam: "TEAM123", candidateVersion: "1.0", expectedSuccess: false)
    }
    func testFrozenReleaseMustBeNewerBeforeDownload() async throws {
        var app = AppUpdateTestFixtures.application(provider: .sparkle)
        app.sparkleConfiguration = .init(feedURL: URL(string: "https://example.com/feed"),
            publicEDKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), requiresSignedFeed: false, frameworkRelativePath: nil)
        let adapter = SparkleAutomaticUpdateAdapter(fetch: { _, _ in XCTFail("No download for a non-newer release") },
            installArchive: { _, _, _, _ in XCTFail("No replacement"); throw SparkleAutomaticUpdateError.noNewVersion })
        let release = SparkleRelease(version: app.installedVersion, downloadURL: URL(string: "https://example.com/update.zip")!,
            edSignature: nil, minimumSystemVersion: nil, maximumSystemVersion: nil, byteCount: nil, isDelta: false)
        do { _ = try await adapter.install(app, release: release) { _ in }; XCTFail("Must reject") }
        catch SparkleAutomaticUpdateError.noNewVersion {}
    }

    func testBuildOnlyAppcastUsesBuildWithoutInventingMarketingVersion() throws {
        let xml = "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel><item><enclosure url='https://example.com/2.zip' sparkle:version='200'/></item></channel></rss>"
        let release = try XCTUnwrap(SparkleAppcastParser.select(Data(xml.utf8), installed: .init(marketing: "1.0", build: "100"), systemVersion: "14.0"))
        XCTAssertEqual(release.version.marketing, "")
        XCTAssertEqual(release.version.build, "200")
        XCTAssertTrue(ApplicationVersion(marketing: "2.0", build: "200").reaches(release.version))
        XCTAssertFalse(ApplicationVersion(marketing: "2.0", build: "199").reaches(release.version))
    }

    func testLegacySparkleRequiresVerifiableInstalledCodeIdentity() async throws {
        var app = AppUpdateTestFixtures.application(provider: .sparkle)
        app.sparkleConfiguration = .init(feedURL: URL(string: "https://example.com/feed"), publicEDKey: nil, requiresSignedFeed: false, frameworkRelativePath: nil)
        app.sourceEvidence = []
        let adapter = SparkleAutomaticUpdateAdapter(fetch: { _, url in try Data("legacy fixture".utf8).write(to: url) },
            installArchive: { _, _, _, _ in XCTFail("Unverified legacy code must not be replaced"); throw SparkleAutomaticUpdateError.invalidSignature })
        let release = SparkleRelease(version: .init(marketing: "2.0"), downloadURL: URL(string: "https://example.com/2.zip")!, edSignature: nil,
            minimumSystemVersion: nil, maximumSystemVersion: nil, byteCount: nil, isDelta: false)
        do { _ = try await adapter.install(app, release: release) { _ in }; XCTFail("Reject unverifiable legacy app") }
        catch SparkleAutomaticUpdateError.invalidSignature {}
    }

    private func exerciseArchive(signatureValid: Bool, candidateTeam: String, candidateVersion: String, expectedSuccess: Bool) async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try makeBundle(root, name: "Installed", version: "1.0")
        let candidate = try makeBundle(root, name: "Candidate", version: candidateVersion)
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("injected download bytes".utf8)
        var app = AppUpdateTestFixtures.application(id: "sparkle", bundleIdentifier: "com.example.sparkle", path: old.path,
            version: "1.0", build: "100", availableVersion: "2.0", provider: .sparkle, status: .automaticallyUpdatable,
            sourceEvidence: ["valid-code-signature", "signed-bundle-identity", "sparkle-framework", "sparkle-feed"],
            canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.sparkleConfiguration = .init(feedURL: URL(string: "https://example.com/appcast.xml"), publicEDKey: key.publicKey.rawRepresentation.base64EncodedString(), requiresSignedFeed: false, frameworkRelativePath: nil)
        let signature = try key.signature(for: signatureValid ? payload : Data("other bytes".utf8)).base64EncodedString()
        let release = SparkleRelease(version: .init(marketing: "2.0", build: "100"), downloadURL: URL(string: "https://example.com/update.zip")!,
            edSignature: signature, minimumSystemVersion: "14.0", maximumSystemVersion: nil, byteCount: Int64(payload.count), isDelta: false)
        let source = OfficialUpdateSource(applicationIdentity: app.identity, providerType: .sparkle, developerName: nil, homepageURL: nil,
            updatePageURL: nil, releaseFeedURL: nil, directDownloadURL: release.downloadURL, allowedHosts: ["example.com"],
            expectedBundleIdentifier: app.bundleIdentifier, expectedTeamIdentifier: "TEAM123", expectedDesignatedRequirement: nil,
            verificationMethod: .sparkleConfiguration, trustLevel: .providerVerified, lastVerifiedAt: nil, capability: .automatic,
            expectedPackageExtensions: ["zip"], officialGitHubRepository: nil)
        let counter = SparkleTestInstallCounter()
        let frozenApp = app
        let adapter = SparkleAutomaticUpdateAdapter(fetch: { _, url in try payload.write(to: url) }, installArchive: { _, app, release, _ in
            await counter.increment()
            let verifier = BundleIdentityVerifier(signatureVerification: { _ in
                .init(isValid: true, codeSigningIdentifier: "com.example.sparkle", teamIdentifier: candidateTeam, designatedRequirement: nil, certificateCommonNames: [], status: 0)
            })
            _ = try verifier.verifyReplacement(at: candidate, for: app, source: source)
            let staged = root.appendingPathComponent(".StorageCleanerMac-Update-" + UUID().uuidString + ".app")
            try FileManager.default.copyItem(at: candidate, to: staged)
            try OfficialApplicationReplacement.replace(destination: old, staged: staged, expectedIdentity: app.identity,
                originalVersion: app.installedVersion, targetVersion: release.version, transactionURL: root.appendingPathComponent("transaction.json"), authenticatedDigest: try AuthenticatedApplicationDigest.compute(staged)) {
                _ = try verifier.verifyReplacement(at: $0, for: frozenApp, source: source)
            }
            return .init(applicationID: app.id, state: .completed, observedVersion: release.version, detail: "fixture verified")
        })
        do {
            _ = try await adapter.install(app, release: release) { _ in }
            XCTAssertTrue(expectedSuccess)
        } catch { XCTAssertFalse(expectedSuccess, "\(error)") }
        let info = try XCTUnwrap(NSDictionary(contentsOf: old.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, expectedSuccess ? "2.0" : "1.0")
        let calls = await counter.count
        XCTAssertEqual(calls, signatureValid ? 1 : 0)
    }

    private func makeBundle(_ root: URL, name: String, version: String) throws -> URL {
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root, name: name, identifier: "com.example.sparkle", version: version)
        // Minimal Mach-O architecture fixture for verification; never launched.
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]).write(to: url.appendingPathComponent("Contents/MacOS/Example"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/Example").path)
        return url
    }
}
private actor SparkleTestInstallCounter { var count = 0; func increment() { count += 1 } }
