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
