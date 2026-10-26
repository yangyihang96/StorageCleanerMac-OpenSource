import CryptoKit
import FanControlShared
import FileOperationShared
import Foundation
import Security
import XCTest

/// D98 ①: the root file-operation helper accepts only the app, and the app
/// only the helper. Each side enforces a requirement that names the peer's
/// bundle identifier, pins the leaf certificate both binaries are signed
/// with and (D102 L2) requires the signer's Team ID.
final class FileOperationPeerRequirementTests: XCTestCase {
    func testOnlyTheTwoPeersOfThisChannelGetARequirement() {
        let application = FileOperationIdentity.application
        for identifier in ["", "com.attacker.app", application + ".evil", application.uppercased(),
                           FileOperationIdentity.authorizationRight, StorageCleanerBuildIdentity.helperLabel] {
            XCTAssertNil(FileOperationPeerRequirement.currentSigner(peerIdentifier: identifier), identifier)
        }
    }

    /// Read independently of the code under test: a process with a certificate
    /// chain gets a requirement that names the peer, pins exactly its own leaf
    /// certificate and requires its Team ID; an ad-hoc or unsigned one gets
    /// none (fails closed).
    func testCurrentSignerPinsThisProcessLeafCertificateOrFailsClosed() throws {
        var own: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &own), errSecSuccess)
        var ownStatic: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(own), [], &ownStatic), errSecSuccess)
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(try XCTUnwrap(ownStatic),
                                                   SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let values = status == errSecSuccess ? information as? [String: Any] : nil
        let leaf = (values?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let team = values?[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        for peer in [FileOperationIdentity.application, FileOperationIdentity.helper] {
            let requirement = FileOperationPeerRequirement.currentSigner(peerIdentifier: peer)
            if let leaf {
                XCTAssertEqual(requirement, Self.expression(peer, Self.fingerprint(leaf), team), peer)
            } else {
                XCTAssertNil(requirement, peer)
            }
        }
    }

    /// The production requirement, checked on an Apple-signed system binary
    /// (which has no Team ID): the identifier clause, the leaf pin and the
    /// Team ID clause each refuse on their own, and only all matching admit
    /// the code.
    func testRequirementRefusesAnotherIdentifierLeafCertificateOrTeam() throws {
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
        func build(_ identifier: String, _ leaf: Data, _ team: String) throws -> String {
            let text = try XCTUnwrap(FileOperationPeerRequirement.expression(identifier: identifier, leafCertificate: leaf,
                                                                            teamIdentifier: team))
            XCTAssertEqual(text, Self.expression(identifier, Self.fingerprint(leaf), team))
            return text
        }

        XCTAssertEqual(validity(of: binary, try build(identifier, leaf, "")), errSecSuccess)
        XCTAssertEqual(validity(of: binary, try build(FileOperationIdentity.application, leaf, "")), errSecCSReqFailed)
        XCTAssertEqual(validity(of: binary, try build(identifier, Data("another leaf".utf8), "")), errSecCSReqFailed)
        XCTAssertEqual(validity(of: binary, try build(identifier, leaf, "T9GZL52H8R")), errSecCSReqFailed)
    }

    /// currentSigner hands its own leaf certificate and Team ID to the
    /// builder checked above, for the two peers only.
    func testCurrentSignerUsesTheCheckedBuilder() throws {
        let body = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "public static func currentSigner(peerIdentifier: String) -> String?",
            in: SwiftSourceScanning.code(try read("Sources/FileOperationShared/FileOperationContract.swift"))))
        XCTAssertTrue(body.hasPrefix(
            "guard[FileOperationIdentity.application,FileOperationIdentity.helper].contains(peerIdentifier)else{returnnil}"), body)
        XCTAssertTrue(body.contains("letleaf=certificates.first"), body)
        XCTAssertTrue(body.hasSuffix("returnexpression(identifier:peerIdentifier,leafCertificate:SecCertificateCopyData(leaf)asData,"
            + "teamIdentifier:values[kSecCodeInfoTeamIdentifierasString]as?String??\"\")"), body)
    }

    /// The helper checks the user and sets the requirement before it exports
    /// or resumes the connection. Each `NSXPCConnection(` in Sources code is
    /// listed here, built inside a function and bound to a name; that same
    /// name gets exactly one requirement, unconditionally and before it is
    /// first resumed or used other than through a member, in that function.
    /// The file-operation clients set the requirement made for that helper's
    /// signer and (D102 L7) the fan-control client the one made for the fan
    /// helper's. Text, not data flow: the checks follow one name.
    func testServerAndEveryClientEnforceTheRequirementBeforeTheConnectionRuns() throws {
        let helper = SwiftSourceScanning.code(try read("Sources/FileOperationHelper/main.swift"))
        let listener = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "shouldAcceptNewConnection connection: NSXPCConnection", in: helper))
        // D195＋旧值：inline `uid >= 501`, `currentSigner(...)`
        // and `setCodeSigningRequirement(requirement)`. Admission now performs
        // both gates under the same lock as exit. Follow that data flow too.
        let admission = try XCTUnwrap(listener.range(of:
            "guardletadmission=lifecycle.admit(uid:connection.effectiveUserIdentifier)else{returnfalse}"))
        let enforce = try XCTUnwrap(listener.range(of: "connection.setCodeSigningRequirement(admission.requirement)"))
        let export = try XCTUnwrap(listener.range(of: "connection.exportedObject="))
        let resume = try XCTUnwrap(listener.range(of: "connection.resume()"))
        XCTAssertLessThan(admission.lowerBound, enforce.lowerBound)
        XCTAssertLessThan(enforce.lowerBound, export.lowerBound)
        XCTAssertLessThan(enforce.lowerBound, resume.lowerBound)
        XCTAssertTrue(SwiftSourceScanning.compact(helper).contains(
            "signer:{FileOperationPeerRequirement.currentSigner(peerIdentifier:FileOperationIdentity.application)}"))
        let lifecycle = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "public func admit(uid:",
            in: SwiftSourceScanning.code(try read("Sources/FileOperationShared/FileOperationHelperLifecycle.swift"))))
        XCTAssertTrue(lifecycle.hasPrefix("lock.withLock{guardacceptsConnections,uid>=501else{returnnil}"))
        let user = try XCTUnwrap(lifecycle.range(of: "uid>=501else{returnnil}"))
        let peer = try XCTUnwrap(lifecycle.range(of: "guardletrequirement=signer()else{"))
        let admitted = try XCTUnwrap(lifecycle.range(of: "returnAdmission(id:id,requirement:requirement)"))
        XCTAssertLessThan(user.lowerBound, peer.lowerBound)
        XCTAssertLessThan(peer.lowerBound, admitted.lowerBound)
        let rejected = String(lifecycle[peer.upperBound..<admitted.lowerBound])
        XCTAssertTrue(rejected.contains("acceptsConnections=false"))
        XCTAssertTrue(rejected.contains("scheduleLocked()returnnil"))

        let construction = try NSRegularExpression(pattern: #"\bNSXPCConnection\s*\("#)
        let binding = try NSRegularExpression(
            pattern: #"(?:\b(?:let|var)\s+)?([A-Za-z_][\w.]*)\s*(?::\s*NSXPCConnection\s*)?=\s*$"#)
        var clients: [String] = [], fileOperationClients: [String] = [], fanControlClients: [String] = []
        for (path, code) in try SwiftSourceScanning.sourceCode().sorted(by: { $0.key < $1.key }) {
            for match in construction.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let site = try XCTUnwrap(Range(match.range, in: code))
                clients.append(path)
                guard let scope = SwiftSourceScanning.enclosingFunctionBody(of: site.lowerBound, in: code) else {
                    XCTFail("\(path): a connection outside a function needs its own check"); continue
                }
                let prefix = String(code[scope.lowerBound..<site.lowerBound])
                guard let bound = binding.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
                      let named = Range(bound.range(at: 1), in: prefix) else {
                    XCTFail("\(path): bind the new connection to a name"); continue
                }
                let name = String(prefix[named])
                let rest = String(code[site.upperBound..<scope.upperBound])
                let fileOperation = SwiftSourceScanning.compact(rest).hasPrefix("machServiceName:FileOperationIdentity.helper")
                let fanControl = SwiftSourceScanning.compact(rest).hasPrefix("machServiceName:Self.helperLabel,options:.privileged)")
                if fileOperation { fileOperationClients.append(path) }
                if fanControl { fanControlClients.append(path) }
                // Matched on the lexed code with token boundaries, so `otherconnection` is not `connection`.
                let receiver = #"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\.\s*"#
                let pins = try Self.ranges(receiver + #"setCodeSigningRequirement\s*\("#, in: rest)
                let starts = try Self.ranges(receiver + #"resume\s*\(\s*\)"#, in: rest)
                guard pins.count == 1, let pin = pins.first, let start = starts.first, pin.upperBound <= start.lowerBound else {
                    XCTFail("\(path): \(name) must get exactly one requirement, before it is first resumed, in this function")
                    continue
                }
                // Set unconditionally, before the connection is aliased or passed anywhere.
                let setup = String(rest[..<pin.lowerBound])
                XCTAssertEqual(setup.filter { $0 == "{" }.count, setup.filter { $0 == "}" }.count,
                               "\(path): \(name) gets its requirement inside a nested block")
                XCTAssertEqual(try Self.ranges(#"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: name)
                                               + #"(?![\w])(?!\s*\.)"#, in: setup).count, 0,
                               "\(path): \(name) is used before its requirement is set")
                XCTAssertTrue(fileOperation || fanControl, "\(path): a connection to another service needs its own check")
                // That one requirement is the one made for the helper's signer, and nothing rebinds it.
                XCTAssertTrue(SwiftSourceScanning.compact(prefix).contains(fileOperation
                    ? "guardletrequirement=FileOperationPeerRequirement.currentSigner(peerIdentifier:FileOperationIdentity.helper)else{"
                    : "guardletrequirement=FanControlPeerRequirement.currentSigner(peerIdentifier:Self.helperLabel)else{"), path)
                XCTAssertTrue(SwiftSourceScanning.compact(rest[pin.upperBound...]).hasPrefix("requirement)"), path)
                // Named exactly twice in the function: bound by that guard, passed to that one call.
                XCTAssertEqual(try Self.ranges(#"(?<![\w.])requirement(?![\w])"#, in: String(code[scope])).count, 2, path)
            }
        }
        // D182＋旧值: adds SystemCacheService (old D177 lists: four clients, three
        // file-operation clients; D177 added the read-only login-item list).
        XCTAssertEqual(clients, [
            "Sources/StorageCleanerMac/Services/AppUpdateProtectedApplicationAuthorization.swift",
            "Sources/StorageCleanerMac/Services/AuthorizedApplicationMover.swift",
            "Sources/StorageCleanerMac/Services/FanControlCoordinator.swift",
            "Sources/StorageCleanerMac/Services/HelperBackgroundTaskInventory.swift",
            "Sources/StorageCleanerMac/Services/SystemCacheService.swift",
        ])
        XCTAssertEqual(fileOperationClients, [
            "Sources/StorageCleanerMac/Services/AppUpdateProtectedApplicationAuthorization.swift",
            "Sources/StorageCleanerMac/Services/AuthorizedApplicationMover.swift",
            "Sources/StorageCleanerMac/Services/HelperBackgroundTaskInventory.swift",
            "Sources/StorageCleanerMac/Services/SystemCacheService.swift",
        ])
        XCTAssertEqual(fanControlClients, ["Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"])
    }

    private static func expression(_ identifier: String, _ fingerprint: String, _ team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
            + (team.isEmpty ? "" : " and certificate leaf[subject.OU] = \"\(team)\"")
    }

    private static func ranges(_ pattern: String, in text: String) throws -> [Range<String.Index>] {
        try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    /// Same digest and spelling as the production requirement.
    private static func fingerprint(_ certificate: SecCertificate) -> String {
        fingerprint(SecCertificateCopyData(certificate) as Data)
    }

    private static func fingerprint(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validity(of code: SecStaticCode, _ text: String) -> OSStatus {
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard created == errSecSuccess, let requirement else { return created }
        return SecStaticCodeCheckValidity(code, [], requirement)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
