import CryptoKit
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateArchiveRepairTests: XCTestCase {
    func testHelperAndClientShareStrictMarketingBuildOrdering() {
        let installed = ApplicationVersion(marketing: "1.0", build: "100")
        for candidate in [ApplicationVersion(marketing: "1.0", build: "101"), .init(marketing: "1.0.0", build: "100"),
            .init(marketing: "1.0", build: "99"), .init(marketing: "", build: "101")] {
            XCTAssertEqual(installed < candidate, ApplicationUpdateVersionOrder.isNewer(marketing: candidate.marketing, build: candidate.build,
                installedMarketing: installed.marketing, installedBuild: installed.build))
        }
        XCTAssertFalse(ApplicationUpdateVersionOrder.isNewer(marketing: "1.0.0", build: "100", installedMarketing: "1.0", installedBuild: "100"))
        XCTAssertTrue(ApplicationUpdateVersionOrder.isNewer(marketing: "1.0", build: "101", installedMarketing: "1.0", installedBuild: "100"))
    }
    func testArchiveReplacementAfterAuthenticationCannotChangeActualExtractedBytes() async throws {
        try await installZIP(marketing: "2.0", build: "200", swapArchive: true, expectedInstall: true)
    }
    func testExtractedTreeSubstitutionBeforeCandidateDigestCannotBecomeExpectedBytes() async throws {
        try await installZIP(marketing: "2.0", build: "200", swapExtractedTree: true, expectedInstall: false)
    }
    func testWritableStagingSubstitutionImmediatelyBeforeSwapPreservesOldApplication() async throws {
        try await installZIP(marketing: "2.0", build: "200", replaceStaging: true, expectedInstall: false)
    }
    func testPostSwapFrozenDigestRefusesTamperedBytesBeforeIdentityAndCleanup() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(root, name: ".StorageCleanerMac-Update-" + UUID().uuidString, marketing: "2.0", build: "200")
        XCTAssertThrowsError(try OfficialApplicationReplacement.replace(destination: old, staged: staged, expectedIdentity: application(at: old).identity,
            originalVersion: .init(marketing: "1.0", build: "100"), targetVersion: .init(marketing: "2.0", build: "200"),
            transactionURL: root.appendingPathComponent("journal.json"), authenticatedDigest: try AuthenticatedApplicationDigest.compute(staged), event: {
                if $0 == .afterSwap {
                    let file = old.appendingPathComponent("Contents/MacOS/Example")
                    var bytes = try Data(contentsOf: file); bytes.append(0x42); try bytes.write(to: file)
                }
            }, verify: { _ in XCTFail("Substituted bytes cannot pass the post-swap digest boundary") }))
        XCTAssertEqual(try version(old), .init(marketing: "1.0", build: "100"))
    }
    func testWritableRollbackFailureRetainsOldBundleStagingAndJournal() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(root, name: ".StorageCleanerMac-Update-" + UUID().uuidString, marketing: "2.0", build: "200")
        let journal = root.appendingPathComponent("journal.json")
        XCTAssertThrowsError(try OfficialApplicationReplacement.replace(destination: old, staged: staged, expectedIdentity: application(at: old).identity,
            originalVersion: .init(marketing: "1.0", build: "100"), targetVersion: .init(marketing: "2.0", build: "200"), transactionURL: journal,
            authenticatedDigest: try AuthenticatedApplicationDigest.compute(staged), event: {
                if $0 == .afterSwap || $0 == .beforeRollback { throw ArchiveFixtureError.injected }
            }, verify: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains(staged.path))
                XCTAssertTrue(error.localizedDescription.contains(journal.path))
            }
        XCTAssertEqual(try version(staged), .init(marketing: "1.0", build: "100"))
        XCTAssertEqual(try version(old), .init(marketing: "2.0", build: "200"))
        let record = try XCTUnwrap(OfficialApplicationReplacementTransactionStore(fileURL: journal).load())
        XCTAssertEqual(record.phase, .rollbackFailed)
        XCTAssertEqual(record.retainedOldURL?.path, staged.path)
        XCTAssertNotNil(record.authenticatedDigest)
        XCTAssertThrowsError(try OfficialApplicationReplacement.reconcilePending(transactionURL: journal, identityVerifier: { _, _ in true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testProtectedSwapRollbackFailureRetainsOldBundleAndFrozenDigestJournal() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(root, name: "RootStaged", marketing: "2.0", build: "200")
        let journal = root.appendingPathComponent("replacement.json")
        let frozen = try AuthenticatedApplicationDigest.compute(staged)
        XCTAssertThrowsError(try AuthenticatedBundleSwap.replace(destination: old, staged: staged, digest: frozen, journal: journal, event: {
            if $0 == .afterSwap || $0 == .beforeRollback { throw ArchiveFixtureError.injected }
        }, verify: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains(staged.path))
            XCTAssertTrue(error.localizedDescription.contains(journal.path))
        }
        XCTAssertEqual(try version(staged), .init(marketing: "1.0", build: "100"))
        let record = try JSONDecoder().decode(AuthenticatedBundleSwap.Journal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(record.phase, "rollbackFailed")
        XCTAssertEqual(record.candidateSHA256, frozen)
        XCTAssertEqual(record.originalSHA256, try AuthenticatedApplicationDigest.compute(staged))
    }
    func testPreDeleteDigestCheckRollsBackSubstitutedInstalledBytes() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(root, name: "RootStaged", marketing: "2.0", build: "200")
        XCTAssertThrowsError(try AuthenticatedBundleSwap.replace(destination: old, staged: staged, digest: try AuthenticatedApplicationDigest.compute(staged),
            journal: root.appendingPathComponent("replacement.json"), event: {
                if $0 == .beforeCleanup { try Data("substituted final executable".utf8).write(to: old.appendingPathComponent("Contents/MacOS/Example")) }
            }, verify: { _ in }))
        XCTAssertEqual(try version(old), .init(marketing: "1.0", build: "100"))
    }
    func testProtectedRollbackSyscallFailureAndDeferredCleanupKeepSoleOldApplication() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let rootStaging = root.appendingPathComponent("PrivateRootStaging")
        try FileManager.default.createDirectory(at: rootStaging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(rootStaging, name: "Staged", marketing: "2.0", build: "200")
        let journal = rootStaging.appendingPathComponent("replacement.json")
        XCTAssertThrowsError(try AuthenticatedBundleSwap.replace(destination: old, staged: staged, digest: try AuthenticatedApplicationDigest.compute(staged),
            journal: journal, verify: { installed in
                try FileManager.default.moveItem(at: installed, to: root.appendingPathComponent("HeldNew.app"))
                throw ArchiveFixtureError.injected
            })) { XCTAssertTrue($0 is AuthenticatedBundleSwap.Failure) }
        AuthenticatedBundleSwap.cleanupStaging(rootStaging, journal: journal)
        XCTAssertEqual(try version(staged), .init(marketing: "1.0", build: "100"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testFullWritableInstallRollbackFailureDoesNotDeferDeleteOldApplication() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Installed", marketing: "1.0", build: "100")
        let payload = try zipPayload(root: root, url: root.appendingPathComponent("Fixture.zip"), marketing: "2.0", build: "200")
        let journal = root.appendingPathComponent("journal.json")
        let installer = OfficialApplicationUpdateInstaller(metadataReader: ArchiveFixtureMetadata(app: application(at: old)), bundleVerifier: verifier(team: "TEAM123"),
            transactionURL: journal, replacementEvent: {
                if $0 == .afterSwap || $0 == .beforeRollback { throw ArchiveFixtureError.injected }
            }, runningStateProvider: { AppUpdatePerformanceTestSupport.idle })
        do {
            _ = try await installer.installVerifiedSparkleArchive(AuthenticatedUpdateArchive(bytes: payload, fileExtension: "zip"),
                application: application(at: old), release: release(marketing: "2.0", build: "200")) { _ in }
            XCTFail("Injected rollback failure")
        } catch OfficialApplicationUpdateInstallerError.rollbackFailed {}
        let record = try XCTUnwrap(OfficialApplicationReplacementTransactionStore(fileURL: journal).load())
        let retained = try XCTUnwrap(record.retainedOldURL)
        XCTAssertEqual(try version(retained), .init(marketing: "1.0", build: "100"))
        XCTAssertEqual(record.phase, .rollbackFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testLegacyJournalWithoutAuthenticatedDigestCannotDeleteBackupOrFinalizeCandidate() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let destination = try bundle(root, name: "Installed", marketing: "2.0", build: "200")
        let backup = try bundle(root, name: ".StorageCleanerMac-Backup-" + UUID().uuidString, marketing: "1.0", build: "100")
        let journal = root.appendingPathComponent("journal.json")
        try OfficialApplicationReplacementTransactionStore(fileURL: journal).save(.init(rootURL: root, destinationURL: destination,
            backupURL: backup, stagedURL: root.appendingPathComponent(".StorageCleanerMac-Update-" + UUID().uuidString + ".app"),
            expectedIdentity: application(at: destination).identity, originalVersion: .init(marketing: "1.0", build: "100"),
            targetVersion: .init(marketing: "2.0", build: "200"), phase: .stagedMovedToDestination))
        XCTAssertThrowsError(try OfficialApplicationReplacement.reconcilePending(transactionURL: journal, identityVerifier: { _, _ in true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testSameMarketingBuildUpgradeInstallsThroughExtractionIdentityAndSwap() async throws {
        try await installZIP(marketing: "1.0", build: "101", expectedInstall: true)
    }
    func testSameVersionAndBuildDowngradePreserveOldApplicationThroughInstallChain() async throws {
        try await installZIP(marketing: "1.0", build: "100", expectedInstall: false)
        try await installZIP(marketing: "1.0", build: "99", expectedInstall: false)
    }
    func testSignedArchiveChangedTeamPreservesOldApplicationInRealExtractionChain() async throws {
        try await installZIP(marketing: "2.0", build: "200", candidateTeam: "OTHER", expectedInstall: false)
    }
    func testDMGCandidateCopiesWhileMountedAndDigestReachesProtectedHelper() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let mounted = root.appendingPathComponent("FakeMountedVolume")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: false)
        let candidate = try bundle(mounted, name: "Candidate", marketing: "2.0", build: "200")
        let sourceApp = application(at: URL(fileURLWithPath: "/Applications/Example.app"))
        let probe = ArchiveRepairProbe()
        let archive = try AuthenticatedUpdateArchive(bytes: Data("fake authenticated DMG".utf8), fileExtension: "dmg")
        let installer = OfficialApplicationUpdateInstaller(metadataReader: ArchiveFixtureMetadata(app: sourceApp), bundleVerifier: verifier(team: "TEAM123"),
            mountAuthenticated: { authenticated, _ in XCTAssertEqual(authenticated.sha256, archive.sha256); await probe.mount(); return [mounted] },
            detachInjected: { _ in await probe.detach() }, protectedReplacement: { privateCandidate, app, digest in
                let isMounted = await probe.mounted
                XCTAssertTrue(isMounted)
                XCTAssertNotEqual(privateCandidate.standardizedFileURL.path, candidate.standardizedFileURL.path)
                XCTAssertTrue(privateCandidate.lastPathComponent.hasPrefix("Candidate-"))
                XCTAssertFalse(privateCandidate.path.hasPrefix(mounted.path + "/"))
                XCTAssertFalse(privateCandidate.path.hasPrefix("/Volumes/"))
                XCTAssertTrue(privateCandidate.path.hasPrefix("/private/"))
                XCTAssertEqual(try AuthenticatedApplicationDigest.compute(privateCandidate), digest)
                XCTAssertEqual(app.path, "/Applications/Example.app")
                await probe.replaced(privateCandidate)
            }, writable: { _ in false }, transactionURL: root.appendingPathComponent("journal.json"), runningStateProvider: { AppUpdatePerformanceTestSupport.idle })
        _ = try await installer.installVerifiedSparkleArchive(archive, application: sourceApp, release: release(marketing: "2.0", build: "200", extension: "dmg")) { _ in }
        let events = await probe.events
        XCTAssertEqual(events, ["mount", "replace", "detach"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }
    func testCandidateChangedAfterAuthenticationFailsRootStagingDigest() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let candidate = try bundle(root, name: "Candidate", marketing: "2.0", build: "200")
        let approved = try AuthenticatedApplicationDigest.compute(candidate)
        try Data("substituted bytes".utf8).write(to: candidate.appendingPathComponent("Contents/MacOS/Example"))
        let rootCopy = root.appendingPathComponent("FakeRootStaging.app")
        try FileManager.default.copyItem(at: candidate, to: rootCopy)
        XCTAssertNotEqual(try AuthenticatedApplicationDigest.compute(rootCopy), approved)
        XCTAssertThrowsError(try AuthenticatedApplicationDigest.authenticateCopy(rootCopy, expectedSHA256: approved))
        try FileManager.default.createSymbolicLink(atPath: candidate.appendingPathComponent("Contents/outside").path, withDestinationPath: root.path)
        XCTAssertThrowsError(try AuthenticatedApplicationDigest.compute(candidate))
    }
    func testAtomicSwapFailuresRestoreOldApplicationWithoutMissingDestination() throws {
        for failure in [OfficialApplicationReplacement.Event.afterSwap, .beforeCleanup] {
            let root = try TestFileSystem.makeHome(for: self)
            let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
            let staged = try bundle(root, name: ".StorageCleanerMac-Update-" + UUID().uuidString, marketing: "2.0", build: "200")
            XCTAssertThrowsError(try OfficialApplicationReplacement.replace(destination: old, staged: staged, expectedIdentity: application(at: old).identity,
                originalVersion: .init(marketing: "1.0", build: "100"), targetVersion: .init(marketing: "2.0", build: "200"),
                transactionURL: root.appendingPathComponent("journal.json"), authenticatedDigest: try AuthenticatedApplicationDigest.compute(staged), event: { event in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "The destination must exist at every injected boundary")
                    if event == failure { throw ArchiveFixtureError.injected }
                }, verify: { _ in }))
            XCTAssertEqual(try version(old), .init(marketing: "1.0", build: "100"))
        }
    }
    func testAtomicSwapCleanupInterruptionKeepsJournalAndReconcilesNewApplication() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Old", marketing: "1.0", build: "100")
        let staged = try bundle(root, name: ".StorageCleanerMac-Update-" + UUID().uuidString, marketing: "2.0", build: "200")
        let journal = root.appendingPathComponent("journal.json")
        XCTAssertThrowsError(try OfficialApplicationReplacement.replace(destination: old, staged: staged, expectedIdentity: application(at: old).identity,
            originalVersion: .init(marketing: "1.0", build: "100"), targetVersion: .init(marketing: "2.0", build: "200"), transactionURL: journal, authenticatedDigest: try AuthenticatedApplicationDigest.compute(staged),
            event: { if $0 == .afterCleanup { throw ArchiveFixtureError.injected } }, verify: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        let reconciled = try OfficialApplicationReplacement.reconcilePending(transactionURL: journal, identityVerifier: { _, _ in true })
        XCTAssertEqual(reconciled, .cleanedCandidate)
        XCTAssertEqual(try version(old), .init(marketing: "2.0", build: "200"))
    }

    private func installZIP(marketing: String, build: String, swapArchive: Bool = false, candidateTeam: String = "TEAM123", swapExtractedTree: Bool = false,
        replaceStaging: Bool = false, expectedInstall: Bool) async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let old = try bundle(root, name: "Installed", marketing: "1.0", build: "100")
        let zip = root.appendingPathComponent("Fixture.zip")
        let payload = try zipPayload(root: root, url: zip, marketing: marketing, build: build)
        let key = Curve25519.Signing.PrivateKey()
        var app = application(at: old)
        app.sparkleConfiguration = .init(feedURL: URL(string: "https://example.com/feed"), publicEDKey: key.publicKey.rawRepresentation.base64EncodedString(), requiresSignedFeed: false, frameworkRelativePath: nil)
        var frozen = release(marketing: marketing, build: build)
        // Equal/lower *candidate* exercises the downstream safety gate with a
        // valid, newer frozen release, rather than failing before extraction.
        if !expectedInstall && marketing == "1.0" { frozen = release(marketing: "2.0", build: "200") }
        let signed = SparkleRelease(version: frozen.version, downloadURL: frozen.downloadURL,
            edSignature: try key.signature(for: payload).base64EncodedString(), minimumSystemVersion: nil, maximumSystemVersion: nil, byteCount: Int64(payload.count), isDelta: false)
        let installer = OfficialApplicationUpdateInstaller(metadataReader: ArchiveFixtureMetadata(app: app), bundleVerifier: verifier(team: candidateTeam),
            transactionURL: root.appendingPathComponent("journal.json"), afterExtraction: { extracted in
                if swapExtractedTree {
                    let file = extracted.appendingPathComponent("Candidate.app/Contents/MacOS/Example")
                    var bytes = try Data(contentsOf: file); bytes.append(0x42); try bytes.write(to: file)
                }
            }, replacementEvent: { event in
                if replaceStaging && event == .afterSwap { XCTFail("Tampered staging must be rejected before swap") }
                if replaceStaging && event == .beforeSwap {
                    let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".StorageCleanerMac-Update-") })
                    let file = stage.appendingPathComponent("Contents/MacOS/Example")
                    var bytes = try Data(contentsOf: file); bytes.append(0x42); try bytes.write(to: file)
                }
            },
            runningStateProvider: { AppUpdatePerformanceTestSupport.idle })
        let adapter = SparkleAutomaticUpdateAdapter(fetch: { _, url in try payload.write(to: url) }, installArchive: { archive, app, release, progress in
            try await installer.installVerifiedSparkleArchive(archive, application: app, release: release, progress: progress)
        }, afterAuthentication: { url in
            if swapArchive { try Data("malicious replacement after EdDSA".utf8).write(to: url, options: .atomic) }
        })
        do { _ = try await adapter.install(app, release: signed) { _ in }; XCTAssertTrue(expectedInstall) }
        catch { XCTAssertFalse(expectedInstall, "\(error)") }
        XCTAssertEqual(try version(old), expectedInstall ? .init(marketing: marketing, build: build) : .init(marketing: "1.0", build: "100"))
    }
    private func zipPayload(root: URL, url: URL, marketing: String, build: String) throws -> Data {
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.sparkle", "CFBundleShortVersionString": marketing, "CFBundleVersion": build, "CFBundleExecutable": "Example"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try StoredZipFixture(entries: [.directory("Candidate.app/"), .directory("Candidate.app/Contents/"), .directory("Candidate.app/Contents/MacOS/"),
            .file("Candidate.app/Contents/Info.plist", data: plist), .executable("Candidate.app/Contents/MacOS/Example", data: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]))]).write(to: url)
        return try Data(contentsOf: url)
    }
    private func application(at url: URL) -> InstalledApplication {
        AppUpdateTestFixtures.application(id: "sparkle", bundleIdentifier: "com.example.sparkle", path: url.path, version: "1.0", build: "100", provider: .sparkle,
            sourceEvidence: ["valid-code-signature", "signed-bundle-identity"], canAutomaticallyUpdate: true, requiresUserInteraction: false)
    }
    private func release(marketing: String, build: String, extension ext: String = "zip") -> SparkleRelease {
        .init(version: .init(marketing: marketing, build: build), downloadURL: URL(string: "https://example.com/update." + ext)!, edSignature: nil,
            minimumSystemVersion: nil, maximumSystemVersion: nil, byteCount: nil, isDelta: false)
    }
    private func verifier(team: String) -> BundleIdentityVerifier {
        .init(signatureVerification: { _ in .init(isValid: true, codeSigningIdentifier: "com.example.sparkle", teamIdentifier: team,
            designatedRequirement: nil, certificateCommonNames: [], status: 0) })
    }
    private func bundle(_ root: URL, name: String, marketing: String, build: String) throws -> URL {
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root, name: name, identifier: "com.example.sparkle", version: marketing)
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: Any]); info["CFBundleVersion"] = build
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]).write(to: url.appendingPathComponent("Contents/MacOS/Example"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/Example").path)
        return url
    }
    private func version(_ url: URL) throws -> ApplicationVersion {
        let info = try XCTUnwrap(NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        return .init(marketing: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "")
    }
}
private enum ArchiveFixtureError: Error { case injected }
private struct ArchiveFixtureMetadata: ApplicationMetadataReading {
    let app: InstalledApplication
    func read(applicationURL: URL, runningState: ApplicationRunningStateSnapshot, scanDate: Date) async -> InstalledApplication? { app }
}
private actor ArchiveRepairProbe {
    var mounted = false; var events = [String]()
    func mount() { mounted = true; events.append("mount") }
    func detach() { mounted = false; events.append("detach") }
    func replaced(_ url: URL) { events.append("replace") }
}
