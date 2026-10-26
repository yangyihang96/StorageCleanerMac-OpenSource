import CryptoKit
import FanControlShared
import FileOperationShared
import Foundation
import Security
import XCTest

/// D102 L7, L1, L2: the requirement each end of the fan-control channel sets
/// on the other, and the Team ID clause both channels' requirements carry.
/// The connection code itself is checked in FileOperationPeerRequirementTests
/// (app side) and HelperUpgradeSafetyTests (helper side).
final class FanControlPeerRequirementTests: XCTestCase {
    /// Only the app calls this, for the helper; the app's own identifier gets
    /// nothing either, since the helper builds its requirement at startup.
    func testOnlyTheHelperGetsARequirement() {
        let helper = StorageCleanerBuildIdentity.helperLabel
        for identifier in ["", "com.attacker.app", helper + ".evil", helper.uppercased(),
                           StorageCleanerBuildIdentity.appBundleIdentifier,
                           StorageCleanerBuildIdentity.appBundleIdentifier + ".evil",
                           FileOperationIdentity.helper, FileOperationIdentity.authorizationRight] {
            XCTAssertNil(FanControlPeerRequirement.currentSigner(peerIdentifier: identifier), identifier)
        }
    }

    /// Read independently of the code under test: a process with a
    /// certificate chain gets a requirement naming the helper, pinning
    /// exactly its own leaf certificate and requiring its Team ID; an ad hoc
    /// or unsigned one gets none, so the app does not connect.
    func testCurrentSignerPinsThisProcessLeafCertificateAndTeamOrFailsClosed() throws {
        let signer = try Self.ownSigner()
        let helper = StorageCleanerBuildIdentity.helperLabel
        let requirement = FanControlPeerRequirement.currentSigner(peerIdentifier: helper)
        if let signer {
            XCTAssertEqual(requirement, Self.expected(helper, signer.leaf, signer.team))
        } else {
            XCTAssertNil(requirement)
        }
    }

    /// The test host (`xctest`) is ad hoc signed, so the two tests above reach
    /// only the nil branch. The source shows the signed branch is open to the
    /// helper alone and hands this process's leaf certificate and Team ID to
    /// the builder checked below.
    func testCurrentSignerUsesTheCheckedBuilder() throws {
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FanControlShared/FanControlPeerRequirement.swift"), encoding: .utf8)
        let body = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "public static func currentSigner(peerIdentifier: String) -> String?", in: SwiftSourceScanning.code(source)))
        XCTAssertTrue(body.hasPrefix("guardpeerIdentifier==StorageCleanerBuildIdentity.helperLabelelse{returnnil}"), body)
        XCTAssertTrue(body.contains("letleaf=certificates.first"), body)
        XCTAssertTrue(body.hasSuffix("returnexpression(identifier:peerIdentifier,leafCertificate:SecCertificateCopyData(leaf)asData,"
            + "teamIdentifier:values[kSecCodeInfoTeamIdentifierasString]as?String??\"\")"), body)
    }

    /// The Team ID clause is added only for a signer with a Team ID, and a
    /// Team ID or identifier that could end the quoted string is refused,
    /// never escaped.
    func testTheTeamClauseAndTheCharactersAllowed() throws {
        let leaf = Data("leaf certificate".utf8)
        let pin = Self.fingerprint(leaf)
        XCTAssertEqual(FanControlPeerRequirement.expression(identifier: "com.example.peer", leafCertificate: leaf,
                                                            teamIdentifier: "T9GZL52H8R"),
                       "anchor apple generic and identifier \"com.example.peer\" and certificate leaf = H\"\(pin)\""
                       + " and certificate leaf[subject.OU] = \"T9GZL52H8R\"")
        XCTAssertEqual(FanControlPeerRequirement.expression(identifier: "com.example.peer", leafCertificate: leaf,
                                                            teamIdentifier: ""),
                       "anchor apple generic and identifier \"com.example.peer\" and certificate leaf = H\"\(pin)\"",
                       "Apple's own code has no Team ID")
        for team in ["T9GZL52H8R\"", "T9GZL52H8R\" or anchor apple", "T9GZ\\L52H8R", "T9GZL52H8R ", "Ｔ9GZL52H8R"] {
            XCTAssertNil(FanControlPeerRequirement.expression(identifier: "com.example.peer", leafCertificate: leaf,
                                                              teamIdentifier: team), team)
            XCTAssertNil(FileOperationPeerRequirement.expression(identifier: "com.example.peer", leafCertificate: leaf,
                                                                 teamIdentifier: team), team)
        }
        for identifier in ["", "com.example.peer\"", "com.example.peer\" or anchor apple", "com example"] {
            XCTAssertNil(FanControlPeerRequirement.expression(identifier: identifier, leafCertificate: leaf,
                                                              teamIdentifier: "T9GZL52H8R"), identifier)
            XCTAssertNil(FileOperationPeerRequirement.expression(identifier: identifier, leafCertificate: leaf,
                                                                 teamIdentifier: "T9GZL52H8R"), identifier)
        }
    }

    /// FanControlShared cannot import FileOperationShared, so each channel
    /// has its own builder; both give the same text for the same signer.
    func testBothChannelsBuildTheSameRequirement() {
        let leaf = Data("another leaf".utf8)
        for team in ["T9GZL52H8R", ""] {
            for identifier in ["com.example.peer", StorageCleanerBuildIdentity.helperLabel, FileOperationIdentity.helper] {
                let fan = FanControlPeerRequirement.expression(identifier: identifier, leafCertificate: leaf, teamIdentifier: team)
                XCTAssertNotNil(fan)
                XCTAssertEqual(fan, FileOperationPeerRequirement.expression(identifier: identifier, leafCertificate: leaf,
                                                                            teamIdentifier: team))
            }
        }
    }

    /// The builder's text, checked by Security on an Apple-signed system
    /// binary (which has no Team ID): it admits the binary, and the
    /// identifier, the leaf pin and the Team ID clause each refuse it alone.
    func testSecurityHonoursEachClause() throws {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &code), errSecSuccess)
        let binary = try XCTUnwrap(code)
        var information: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(binary, SecCSFlags(rawValue: kSecCSSigningInformation), &information),
                       errSecSuccess)
        let values = try XCTUnwrap(information as? [String: Any])
        let identifier = try XCTUnwrap(values[kSecCodeInfoIdentifier as String] as? String)
        let leaf = SecCertificateCopyData(try XCTUnwrap((values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first)) as Data
        XCTAssertNil(values[kSecCodeInfoTeamIdentifier as String])

        func validity(_ text: String?) throws -> OSStatus {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(try XCTUnwrap(text) as CFString, [], &requirement), errSecSuccess)
            return SecStaticCodeCheckValidity(binary, [], try XCTUnwrap(requirement))
        }
        let build = FanControlPeerRequirement.expression
        XCTAssertEqual(try validity(build(identifier, leaf, "")), errSecSuccess)
        XCTAssertEqual(try validity(build(identifier, leaf, "T9GZL52H8R")), errSecCSReqFailed)
        XCTAssertEqual(try validity(build(StorageCleanerBuildIdentity.helperLabel, leaf, "")), errSecCSReqFailed)
        XCTAssertEqual(try validity(build(identifier, Data("another leaf".utf8), "")), errSecCSReqFailed)
    }

    private static func ownSigner() throws -> (leaf: Data, team: String)? {
        var own: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &own), errSecSuccess)
        var ownStatic: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(own), [], &ownStatic), errSecSuccess)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(try XCTUnwrap(ownStatic), SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let values = information as? [String: Any],
              let leaf = (values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
        return (SecCertificateCopyData(leaf) as Data, values[kSecCodeInfoTeamIdentifier as String] as? String ?? "")
    }

    private static func expected(_ identifier: String, _ leaf: Data, _ team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint(leaf))\""
            + (team.isEmpty ? "" : " and certificate leaf[subject.OU] = \"\(team)\"")
    }

    /// Same digest and spelling as the production requirement.
    private static func fingerprint(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
