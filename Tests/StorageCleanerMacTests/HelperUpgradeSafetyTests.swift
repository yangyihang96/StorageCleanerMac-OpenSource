import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class HelperUpgradeSafetyTests: XCTestCase {
    private let old = HelperExecutableStamp(token: "old-vnode")
    private let new = HelperExecutableStamp(token: "new-vnode")
    private let oldHash = Data([1])
    private let newHash = Data([2])

    func testOldAndNewAppBuildsWithSameSigningIdentityAreBothAuthorized() {
        // The build label is fixture context, not an input to authorization.
        for build in ["20261009010000", "20261010015823"] {
            XCTAssertTrue(HelperClientSigningPolicy.permits(helperCertificates: [Data([10]), Data([11])],
                clientCertificates: [Data([10]), Data([11])], clientIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier,
                expectedIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier), build)
        }
    }

    func testChangedCertificateOrBundleIdentifierStillRejectsNewBuild() {
        for client in [[], [Data([10])], [Data([20]), Data([11])]] {
            XCTAssertFalse(HelperClientSigningPolicy.permits(helperCertificates: [Data([10]), Data([11])],
                clientCertificates: client, clientIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier,
                expectedIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier))
        }
        XCTAssertFalse(HelperClientSigningPolicy.permits(helperCertificates: [], clientCertificates: [],
            clientIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier,
            expectedIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier))
        XCTAssertFalse(HelperClientSigningPolicy.permits(helperCertificates: [oldHash], clientCertificates: [oldHash],
            clientIdentifier: "com.attacker.app", expectedIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier))
    }

    /// D98 ②: even with the very same chain,
    /// only the app's exact bundle identifier is a fan-control client; the
    /// helpers, the Finder extension and the other channel's app are not.
    func testSameCertificatesWithAnotherIdentifierAreRejected() {
        let chain = [Data([10]), Data([11])]
        let app = StorageCleanerBuildIdentity.appBundleIdentifier
        let otherChannel = StorageCleanerBuildIdentity.isBeta ? "com.local.StorageCleanerMac" : "com.local.StorageCleanerMac.beta"
        for identifier in ["", StorageCleanerBuildIdentity.helperLabel, app + ".FileOperationHelper",
                           app + ".FinderUninstall", otherChannel, app.uppercased(), app + " "] {
            XCTAssertFalse(HelperClientSigningPolicy.permits(helperCertificates: chain, clientCertificates: chain,
                clientIdentifier: identifier, expectedIdentifier: app), identifier)
        }
        XCTAssertFalse(HelperClientSigningPolicy.permits(helperCertificates: chain, clientCertificates: Array(chain.reversed()),
            clientIdentifier: app, expectedIdentifier: app))
    }

    func testOnlyCompleteClientAuthorityAndTrustedChangedBinaryCanYield() {
        for original in [false, true] {
            for installedTeam in [false, true] {
                for replacement in [false, true] {
                    XCTAssertEqual(HelperUpgradeSafety.shouldYield(originalClientValid: original,
                        installedTeamClientValid: installedTeam, startupStamp: old, currentStamp: new,
                        runningCodeHash: oldHash, replacementCodeHash: newHash,
                        runningBuild: HelperSignedBuildVersion("20261009010000"), replacementBuild: HelperSignedBuildVersion("20261010015823"),
                        replacementSignatureValid: replacement), original && installedTeam && replacement)
                }
            }
        }
    }

    func testSameBinaryMetadataOnlyChangeAndUnknownEvidenceCannotYield() {
        XCTAssertFalse(yields(stamp: old, hash: newHash))
        XCTAssertFalse(yields(stamp: new, hash: oldHash), "Touching metadata is not an executable update")
        XCTAssertFalse(yields(stamp: nil, hash: newHash))
        XCTAssertFalse(yields(stamp: new, hash: nil))
        XCTAssertFalse(yields(stamp: new, hash: Data()))
        XCTAssertFalse(HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
            startupStamp: nil, currentStamp: new, runningCodeHash: oldHash, replacementCodeHash: newHash,
            runningBuild: HelperSignedBuildVersion("20261009010000"), replacementBuild: HelperSignedBuildVersion("20261010015823"),
                        replacementSignatureValid: true))
        XCTAssertTrue(yields(stamp: new, hash: newHash))
    }

    func testOnlyStrictlyNewerSignedBuildCanYieldDespiteDifferentHash() {
        let running = HelperSignedBuildVersion("20261010015823")
        for (version, allowed) in [("20261009010000", false), ("20261010015823", false), ("20261010015824", true)] {
            XCTAssertEqual(HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
                startupStamp: old, currentStamp: new, runningCodeHash: oldHash, replacementCodeHash: newHash,
                runningBuild: running, replacementBuild: HelperSignedBuildVersion(version),
                replacementSignatureValid: true), allowed, version)
        }
        XCTAssertFalse(HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
            startupStamp: old, currentStamp: new, runningCodeHash: oldHash, replacementCodeHash: newHash,
            runningBuild: nil, replacementBuild: running, replacementSignatureValid: true))
        XCTAssertFalse(HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
            startupStamp: old, currentStamp: new, runningCodeHash: oldHash, replacementCodeHash: newHash,
            runningBuild: running, replacementBuild: nil, replacementSignatureValid: true))
    }

    func testSignedBuildRejectsAmbiguousOrUnboundedNumbers() {
        for text in ["", "0", "01", "+2", "-2", "2.0", " 2", "2\n", "２", "18446744073709551616"] {
            XCTAssertNil(HelperSignedBuildVersion(text), text)
        }
        XCTAssertEqual(HelperSignedBuildVersion("18446744073709551615")?.value, UInt64.max)
        XCTAssertLessThan(HelperSignedBuildVersion("9")!, HelperSignedBuildVersion("10")!)
    }

    func testFinalValidationFailureResumesServiceWithoutExitAfterRecovery() {
        for valid in [false, true] {
            var events: [String] = []
            _ = HelperUpgradeSafety.prepareForExit(stopRequestsAndSampling: { events.append("drain") },
                restoreSleep: { events.append("sleep"); return true },
                restoreFans: { events.append("fans"); return true })
            HelperUpgradeSafety.finishHandoff(revalidateAndRecord: { events.append("fresh-check"); return valid },
                resumeService: { events.append("resume") }, exitProcess: { events.append("exit") })
            XCTAssertEqual(events, ["drain", "sleep", "fans", "fresh-check", valid ? "exit" : "resume"])
        }
    }

    func testFinalDaemonCheckRepeatsIdentityAndCancelsIdleExit() throws {
        let source = try read("Sources/FanControlHelper/main.swift")
        let final = try MiniWindowLogicFixtures.section(source, from: "HelperUpgradeSafety.finishHandoff", to: "private func readPowerConfiguration")
        XCTAssertTrue(final.contains("upgradeLedger.commitIfPermitted"))
        XCTAssertTrue(final.contains("CodeSigningCheck.validatedReplacement(startup: startupIdentity) == replacement"))
        XCTAssertTrue(final.contains("acceptsRequests = true"))
        XCTAssertTrue(final.contains("powerSamplingRunner.resumeAfterCancelledTermination()"))
        XCTAssertTrue(final.contains("macMiniRuntime?.start()"))
        XCTAssertTrue(final.contains("cancelledHandoffKeepsResident = true"))
        let idle = try MiniWindowLogicFixtures.section(source, from: "private func scheduleIdleExit()", to: "private func startTerminationHandlers()")
        XCTAssertTrue(idle.contains("!self.cancelledHandoffKeepsResident"))
        let check = try MiniWindowLogicFixtures.section(source, from: "static func validatedReplacement", to: "static func clientProcess")
        for gate in ["kSecCSStrictValidate", "kSecCSCheckAllArchitectures", "replacement.identifier == StorageCleanerBuildIdentity.helperLabel",
                     "replacement.teamIdentifier == startup.signing.teamIdentifier", "replacement.certificates == startup.signing.certificates",
                     "replacement.executableURL?.standardizedFileURL.path == expectedPath", "runningBuild: startup.signing.signedBuild"] {
            XCTAssertTrue(check.contains(gate), gate)
        }
        XCTAssertTrue(source.contains("signedInfo?[\"CFBundleIdentifier\"] as? String == StorageCleanerBuildIdentity.helperLabel"))
        XCTAssertTrue(source.contains("kSecCodeInfoPList"))
    }

    func testRestoreCompletesBeforeExitDecisionEvenWhenSleepFails() {
        for sleep in [false, true] {
            for fans in [false, true] {
                var events: [String] = []
                let succeeded = HelperUpgradeSafety.prepareForExit(stopRequestsAndSampling: { events.append("stop") },
                    restoreSleep: { events.append("sleep"); return sleep },
                    restoreFans: { events.append("fans"); return fans })
                events.append("exit-decision")
                XCTAssertEqual(events, ["stop", "sleep", "fans", "exit-decision"])
                XCTAssertEqual(succeeded, sleep && fans)
            }
        }
    }

    func testStampDetectsAtomicReplacementAndRejectsSymlinkAndMissingFile() throws {
        let root = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let executable = root.appendingPathComponent("helper")
        try Data([1]).write(to: executable)
        let before = try XCTUnwrap(HelperExecutableStamp.read(at: executable))
        XCTAssertEqual(HelperExecutableStamp.read(at: executable), before)
        try Data([2, 3]).write(to: executable, options: .atomic)
        XCTAssertNotEqual(HelperExecutableStamp.read(at: executable), before)
        let link = root.appendingPathComponent("helper-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertNil(HelperExecutableStamp.read(at: link))
        XCTAssertNil(HelperExecutableStamp.read(at: root))
        XCTAssertNil(HelperExecutableStamp.read(at: root.appendingPathComponent("missing")))
    }

    func testListenerChecksOriginalAuthorityBeforeYieldAndUsesNoUpgradeRPC() throws {
        let source = try read("Sources/FanControlHelper/main.swift")
        let listener = try XCTUnwrap(source.range(of: "shouldAcceptNewConnection newConnection"))
        let admission = try XCTUnwrap(source.range(of: "newConnection.exportedInterface", range: listener.upperBound..<source.endIndex))
        let body = String(source[listener.lowerBound..<admission.lowerBound])
        let original = try XCTUnwrap(body.range(of: "clientMatchesHelper(auditToken:"))
        let handoff = try XCTUnwrap(body.range(of: "shouldYieldToReplacement(auditToken:"))
        XCTAssertLessThan(original.lowerBound, handoff.lowerBound)
        XCTAssertTrue(body.contains("helperIdentity: startupIdentity.signing"))
        XCTAssertTrue(source.contains("powerSamplingClientIdentityMatches(auditToken: auditToken)"))
        XCTAssertTrue(source.contains("powerSamplingClientSealIsValid(auditToken: auditToken)"))
        XCTAssertTrue(source.contains("replacement.certificates == startup.signing.certificates"))
        XCTAssertTrue(source.contains("pendingRequestCount == 0"))
        XCTAssertTrue(source.contains("fanCurveController = nil"))
        XCTAssertFalse(source.contains("case upgradeHelper"))
    }

    /// D98 ②: before anything is exported the listener needs the startup
    /// identity, the client's audit token and a passing check, and refuses on
    /// any Security error. The check validates the code behind that exact
    /// audit token, then compares its chain with the helper's own and its
    /// identifier with the app's. Comments and strings are blanked and
    /// whitespace ignored, so neither documentation nor layout decides.
    func testClientCheckComparesTheAuditTokenCodeWithTheHelperChain() throws {
        let compact = SwiftSourceScanning.compact(SwiftSourceScanning.code(try read("Sources/FanControlHelper/main.swift")))
        func body(_ marker: String, in text: String) throws -> String { try SwiftSourceScanning.body(of: marker, in: text) }

        let listener = try body("shouldAcceptNewConnectionnewConnection:NSXPCConnection)->Bool", in: compact)
        XCTAssertTrue(listener.hasPrefix("do{guardletstartupIdentity,lettoken=CodeSigningCheck.auditToken(for:newConnection),"
            + "tryCodeSigningCheck.clientMatchesHelper(auditToken:token,helperIdentity:startupIdentity.signing)else{"), listener)
        XCTAssertTrue(try body("helperIdentity:startupIdentity.signing)else", in: listener).hasSuffix("returnfalse"))
        XCTAssertTrue(try body("}catch", in: listener).hasSuffix("returnfalse"))
        let export = try XCTUnwrap(listener.range(of: "newConnection.exportedInterface="))
        XCTAssertFalse(listener[..<export.lowerBound].contains("returntrue"))
        XCTAssertTrue(listener.hasSuffix("newConnection.resume()returntrue"), listener)

        XCTAssertEqual(try body("staticfuncclientMatchesHelper(auditToken:audit_token_t,helperIdentity:SigningIdentity)throws->Bool",
                                in: compact),
                       "letclientIdentity=trysigningIdentity(for:auditToken)returnHelperClientSigningPolicy.permits("
                       + "helperCertificates:helperIdentity.certificates.map{SecCertificateCopyData($0)asData},"
                       + "clientCertificates:clientIdentity.certificates.map{SecCertificateCopyData($0)asData},"
                       + "clientIdentifier:clientIdentity.identifier,expectedIdentifier:mainApplicationIdentifier)")
        XCTAssertTrue(compact.contains("privatestaticletmainApplicationIdentifier=StorageCleanerBuildIdentity.appBundleIdentifier"))

        let guest = try body("privatestaticfuncsigningIdentity(forauditToken:audit_token_t)throws->SigningIdentity", in: compact)
        XCTAssertTrue(guest.hasPrefix("lettokenData=withUnsafeBytes(of:auditToken){Data($0)}asCFData"), guest)
        XCTAssertTrue(guest.contains(
            "trycheck(SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit:tokenData]asCFDictionary,[],&code))"), guest)
        XCTAssertTrue(guest.hasSuffix("returntrysigningIdentity(for:staticCode)"), guest)
        let identity = try body("privatestaticfuncsigningIdentity(forcode:SecStaticCode)throws->SigningIdentity", in: compact)
        XCTAssertTrue(identity.hasPrefix("trycheck(SecStaticCodeCheckValidity(code,"), identity)
        XCTAssertTrue(identity.contains("identifier:values?[kSecCodeInfoIdentifierasString]"), identity)
        XCTAssertTrue(identity.contains("certificates:values?[kSecCodeInfoCertificatesasString]"), identity)
    }

    /// D102 L1: after those checks and before anything is exported, the
    /// listener sets the requirement built once at startup for the app (its
    /// identifier, this helper's leaf certificate and Team ID) and refuses
    /// when there is none. The client's running code must also be valid, not
    /// only its file. Start-up fan recovery still runs before the listener
    /// opens, never through a connection.
    func testListenerSetsTheStartupRequirementBeforeExport() throws {
        let compact = SwiftSourceScanning.compact(SwiftSourceScanning.code(try read("Sources/FanControlHelper/main.swift")))
        func body(_ marker: String, in text: String) throws -> String { try SwiftSourceScanning.body(of: marker, in: text) }

        let listener = try body("shouldAcceptNewConnectionnewConnection:NSXPCConnection)->Bool", in: compact)
        let order = try ["CodeSigningCheck.clientMatchesHelper(auditToken:", "CodeSigningCheck.shouldYieldToReplacement(auditToken:",
                         "}catch{", "guardletclientRequirementelse{", "newConnection.setCodeSigningRequirement(clientRequirement)",
                         "newConnection.exportedInterface=", "newConnection.resume()"]
            .map { try XCTUnwrap(listener.range(of: $0), $0).lowerBound }
        XCTAssertEqual(order, order.sorted(), listener)
        XCTAssertTrue(try body("guardletclientRequirementelse", in: listener).hasSuffix("returnfalse"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "setCodeSigningRequirement(", in: compact), 1)

        let initializer = try body("overrideinit()", in: compact)
        let startup = try XCTUnwrap(initializer.range(of: "startupIdentity=tryCodeSigningCheck.captureStartupIdentity()"))
        let built = try XCTUnwrap(initializer.range(of: "clientRequirement=startupIdentity.flatMap{identityin"
            + "identity.signing.certificates.first.flatMap{leafin"
            + "FanControlPeerRequirement.expression(identifier:StorageCleanerBuildIdentity.appBundleIdentifier,"
            + "leafCertificate:SecCertificateCopyData(leaf)asData,teamIdentifier:identity.signing.teamIdentifier)}}"), initializer)
        XCTAssertLessThan(startup.lowerBound, built.lowerBound)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "clientRequirement=", in: compact), 1, "set only at startup")

        let guest = try body("privatestaticfuncsigningIdentity(forauditToken:audit_token_t)throws->SigningIdentity", in: compact)
        let steps = try ["trycheck(SecCodeCopyGuestWithAttributes(", "trycheck(SecCodeCheckValidity(code,[],nil))",
                         "trycheck(SecCodeCopyStaticCode(code,[],&staticCode))"]
            .map { try XCTUnwrap(guest.range(of: $0), $0).lowerBound }
        XCTAssertEqual(steps, steps.sorted(), guest)

        let run = try body("funcrun()", in: compact)
        let recovery = try XCTUnwrap(run.range(of: "startupSafety.start(recoverFans:"))
        let open = try XCTUnwrap(run.range(of: "listener.resume()"))
        XCTAssertLessThan(recovery.lowerBound, open.lowerBound)
    }

    func testLaunchdRestartsOnlyUnsuccessfulExitAndRetainsDemandService() throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Resources/com.local.StorageCleanerMac.FanControlHelper.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNotNil(plist["MachServices"])
    }

    private func yields(stamp: HelperExecutableStamp?, hash: Data?) -> Bool {
        HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
            startupStamp: old, currentStamp: stamp, runningCodeHash: oldHash, replacementCodeHash: hash,
            runningBuild: HelperSignedBuildVersion("20261009010000"), replacementBuild: HelperSignedBuildVersion("20261010015823"),
                        replacementSignatureValid: true)
    }
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func read(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
