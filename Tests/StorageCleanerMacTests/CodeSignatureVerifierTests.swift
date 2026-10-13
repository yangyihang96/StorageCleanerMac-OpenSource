import Foundation
import Security
import XCTest
@testable import StorageCleanerMac

/// A self-signed certificate can carry any Team ID in its subject, and an
/// ad-hoc signature can declare one outright. Update and ownership checks
/// compare Team IDs, so only valid, Apple-anchored values count.
final class CodeSignatureVerifierTests: XCTestCase {
    private static let declaredTeam = "ABCDE12345"
    private static let fixtureBundleIdentifier = "com.example.adhoc-team"

    func testTeamIdentifierIsTrustedOnlyForAppleAnchoredSignatures() {
        XCTAssertNil(CodeSignatureVerifier.trustedTeamIdentifier(reported: "ABCDE12345", isAppleAnchored: false))
        XCTAssertEqual(CodeSignatureVerifier.trustedTeamIdentifier(reported: "ABCDE12345", isAppleAnchored: true),
                       "ABCDE12345")
    }

    func testAppleSignedAppIsAnchoredAndALocallySignedBundleIsNot() throws {
        let apple = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: apple.path), "No Apple app to compare with")
        XCTAssertTrue(try anchored(apple))
        XCTAssertTrue(UninstallOwnershipVerifier.hasAppleAnchor(apple.path))
        XCTAssertNotNil(try CodeSignatureVerifier().verifyCode(at: apple).codeSigningIdentifier)
        // The test bundle is built locally: never Apple-anchored.
        XCTAssertFalse(try anchored(Bundle(for: Self.self).bundleURL))
        XCTAssertFalse(UninstallOwnershipVerifier.hasAppleAnchor(Bundle(for: Self.self).bundleURL.path))
    }

    func testVerifierDropsTheTeamIDThatAValidAdHocSignatureDeclares() throws {
        let fixture = try makeAdHocBundleDeclaringTeam()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = try CodeSignatureVerifier().verifyCode(at: fixture)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.codeSigningIdentifier, Self.fixtureBundleIdentifier)
        XCTAssertNil(result.teamIdentifier, "A declared Team ID without an Apple anchor must not be reported")
    }

    func testMetadataInspectorDropsTheTeamIDThatAValidAdHocSignatureDeclares() async throws {
        let fixture = try makeAdHocBundleDeclaringTeam()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let metadata = await SecurityFrameworkApplicationCodeSignatureInspector().inspectSignature(at: fixture)

        XCTAssertTrue(metadata.isValid)
        XCTAssertEqual(metadata.codeSigningIdentifier, Self.fixtureBundleIdentifier)
        XCTAssertNil(metadata.signingTeamIdentifier, "A declared Team ID without an Apple anchor must not be reported")
    }

    func testMetadataReaderGivesANonAppleSignedAppNoTeamIdentity() async throws {
        let fixture = try makeAdHocBundleDeclaringTeam()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let read = await ApplicationMetadataReader().read(
            applicationURL: fixture,
            runningState: ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])
        )
        let application = try XCTUnwrap(read)

        XCTAssertEqual(application.bundleIdentifier, Self.fixtureBundleIdentifier)
        XCTAssertTrue(application.sourceEvidence.contains("valid-code-signature"))
        XCTAssertNil(application.signingTeamIdentifier)
        XCTAssertFalse(application.sourceEvidence.contains("signed-bundle-identity"))
        XCTAssertFalse(application.identity.isCompleteForAutomaticUpdates)
    }

    func testReplacementIdentityCheckNeedsAnExpectedTeam() throws {
        let fixture = try makeAdHocBundleDeclaringTeam()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let verify = OfficialApplicationReplacement.defaultIdentityVerifier

        // Both sides without a Team ID used to count as a match.
        XCTAssertFalse(try verify(fixture, ApplicationIdentity(
            bundleIdentifier: Self.fixtureBundleIdentifier,
            signingTeamIdentifier: nil,
            codeSigningIdentifier: Self.fixtureBundleIdentifier
        )))
        // The declared Team ID is not trusted either.
        XCTAssertFalse(try verify(fixture, ApplicationIdentity(
            bundleIdentifier: Self.fixtureBundleIdentifier,
            signingTeamIdentifier: Self.declaredTeam,
            codeSigningIdentifier: Self.fixtureBundleIdentifier
        )))
    }

    private func anchored(_ url: URL) throws -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw XCTSkip("Cannot read the code object at \(url.lastPathComponent)")
        }
        return CodeSignatureVerifier.isAppleAnchored(code)
    }

    /// A minimal app whose ad-hoc signature declares a Team ID: valid, but not
    /// Apple-anchored. This is the forged identity the checks must not trust.
    private func makeAdHocBundleDeclaringTeam() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeSignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
        let bundle = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appendingPathComponent("Fixture", isDirectory: false)
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": Self.fixtureBundleIdentifier,
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--team-identifier", Self.declaredTeam, bundle.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0, "codesign could not sign the fixture")

        // The fixture is only meaningful if its signature really declares the
        // Team ID that the checks above must ignore.
        var code: SecStaticCode?
        var information: CFDictionary?
        XCTAssertEqual(SecStaticCodeCreateWithPath(bundle as CFURL, [], &code), errSecSuccess)
        let staticCode = try XCTUnwrap(code)
        XCTAssertEqual(
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information),
            errSecSuccess
        )
        let declared = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        XCTAssertEqual(declared, Self.declaredTeam)
        XCTAssertFalse(CodeSignatureVerifier.isAppleAnchored(staticCode))
        return bundle
    }
}
