import CryptoKit
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateOfficialSecurityTests: XCTestCase {
    func testExplicitLiveOfficialDownloadMountPipelineWhenRequested() async throws {
        guard let installedPath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_INSTALLED"] else {
            throw XCTSkip("Explicit live official download was not requested")
        }

        let runningState = ApplicationRunningStateSnapshot(
            bundleIdentifiers: [],
            normalizedBundlePaths: []
        )
        let scannedApplication = await ApplicationMetadataReader().read(
            applicationURL: URL(fileURLWithPath: installedPath, isDirectory: true),
            runningState: runningState
        )
        var application = try XCTUnwrap(scannedApplication)
        let sourceValue = await OfficialSourceRegistry().source(for: application)
        let source = try XCTUnwrap(sourceValue)
        application.officialSource = source

        let releaseValue = try await OfficialGitHubReleaseAdapter().latestRelease(for: source)
        let release = try XCTUnwrap(releaseValue)
        let download = try OfficialDownloadResolver().resolve(
            for: application,
            release: release
        )
        let context = OfficialApplicationUpdateContext(
            application: application,
            source: source,
            download: download
        )
        let installer = OfficialApplicationUpdateInstaller()
        let staged = try await installer.stage(
            context: context,
            targetVersion: release.version,
            progress: { _ in }
        )
        defer { installer.cleanup(staged) }

        let mountPoints = try await installer.mountReadOnly(staged.packageURL)
        do {
            let discoveredCandidates = try OfficialApplicationUpdateInstaller
                .applicationBundleCandidates(in: mountPoints)
            XCTAssertFalse(discoveredCandidates.isEmpty)
            let candidate = try installer.verifiedCandidate(
                in: mountPoints,
                application: application,
                source: source,
                targetVersion: release.version,
                requiresSingleApplicationBundle: false
            )
            XCTAssertEqual(candidate.pathExtension.lowercased(), "app")
            XCTAssertEqual(staged.downloadURL, download.remoteURL)
            await installer.detach(mountPoints)
        } catch {
            await installer.detach(mountPoints)
            throw error
        }
    }

    func testExplicitRealOfficialApplicationCandidateWhenRequested() async throws {
        guard let candidatePath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_CANDIDATE"],
              let installedPath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_INSTALLED"],
              let bundleIdentifier = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_BUNDLE_ID"],
              let teamIdentifier = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_TEAM_ID"],
              let installedVersion = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_INSTALLED_VERSION"]
        else {
            throw XCTSkip("Explicit real update candidate was not requested")
        }

        let application = AppUpdateTestFixtures.application(
            bundleIdentifier: bundleIdentifier,
            path: installedPath,
            version: installedVersion,
            build: installedVersion,
            signingTeamIdentifier: teamIdentifier,
            codeSigningIdentifier: bundleIdentifier,
            provider: .officialWebsite,
            status: .automaticallyUpdatable,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let source = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialGitHubRelease,
            developerName: nil,
            homepageURL: URL(string: "https://github.com"),
            updatePageURL: URL(string: "https://github.com"),
            releaseFeedURL: nil,
            directDownloadURL: URL(string: "https://github.com/example/example/releases/download/v1/Example.dmg"),
            allowedHosts: OfficialGitHubRepositoryPolicy.assetDownloadHosts,
            expectedBundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: teamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .vendorManifest,
            trustLevel: .verified,
            lastVerifiedAt: Date(),
            capability: .automatic,
            expectedPackageExtensions: ["dmg"],
            officialGitHubRepository: "example/example"
        )
        let result = try BundleIdentityVerifier().verifyReplacement(
            at: URL(fileURLWithPath: candidatePath, isDirectory: true),
            for: application,
            source: source
        )
        XCTAssertEqual(result.candidateIdentity.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(result.candidateIdentity.signingTeamIdentifier, teamIdentifier)
        XCTAssertGreaterThan(result.candidateVersion, application.installedVersion)
    }

    func testExplicitRealOfficialInstallerPipelineWhenRequested() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_ROOT"],
              let candidatePath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_CANDIDATE"],
              let installedPath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_INSTALLED"],
              let targetVersion = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_TARGET_VERSION"]
        else {
            throw XCTSkip("Explicit real update installer pipeline was not requested")
        }

        let runningState = ApplicationRunningStateSnapshot(
            bundleIdentifiers: [],
            normalizedBundlePaths: []
        )
        let scannedApplication = await ApplicationMetadataReader().read(
            applicationURL: URL(fileURLWithPath: installedPath, isDirectory: true),
            runningState: runningState
        )
        var application = try XCTUnwrap(scannedApplication)
        let resolvedSource = await OfficialSourceRegistry().source(for: application)
        let source = try XCTUnwrap(resolvedSource)
        application.officialSource = source

        let candidate = try OfficialApplicationUpdateInstaller().verifiedCandidate(
            in: [URL(fileURLWithPath: rootPath, isDirectory: true)],
            application: application,
            source: source,
            targetVersion: ApplicationVersion(marketing: targetVersion),
            requiresSingleApplicationBundle: false
        )
        XCTAssertEqual(
            candidate.standardizedFileURL.resolvingSymlinksInPath(),
            URL(fileURLWithPath: candidatePath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testExplicitRealDiskImageMountPipelineWhenRequested() async throws {
        guard let imagePath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_IMAGE"],
              let candidatePath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_CANDIDATE"],
              let installedPath = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_INSTALLED"],
              let targetVersion = ProcessInfo.processInfo.environment["APP_UPDATE_AUDIT_TARGET_VERSION"]
        else {
            throw XCTSkip("Explicit real update disk image was not requested")
        }

        let runningState = ApplicationRunningStateSnapshot(
            bundleIdentifiers: [],
            normalizedBundlePaths: []
        )
        let scannedApplication = await ApplicationMetadataReader().read(
            applicationURL: URL(fileURLWithPath: installedPath, isDirectory: true),
            runningState: runningState
        )
        var application = try XCTUnwrap(scannedApplication)
        let resolvedSource = await OfficialSourceRegistry().source(for: application)
        let source = try XCTUnwrap(resolvedSource)
        application.officialSource = source

        let installer = OfficialApplicationUpdateInstaller()
        let mountPoints = try await installer.mountReadOnly(
            URL(fileURLWithPath: imagePath, isDirectory: false)
        )
        do {
            let candidate = try installer.verifiedCandidate(
                in: mountPoints,
                application: application,
                source: source,
                targetVersion: ApplicationVersion(marketing: targetVersion),
                requiresSingleApplicationBundle: false
            )
            XCTAssertEqual(
                candidate.lastPathComponent,
                URL(fileURLWithPath: candidatePath, isDirectory: true).lastPathComponent
            )
            await installer.detach(mountPoints)
        } catch {
            await installer.detach(mountPoints)
            throw error
        }
    }

    func testOfficialDownloadRetryIsBoundedAndOnlyCoversTransientFailures() {
        XCTAssertTrue(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: URLError(.timedOut),
                attempt: 1
            )
        )
        XCTAssertTrue(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: OfficialApplicationUpdateInstallerError.transientResponse(statusCode: 503),
                attempt: 1
            )
        )
        XCTAssertFalse(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: OfficialApplicationUpdateInstallerError.transientResponse(statusCode: 404),
                attempt: 1
            )
        )
        XCTAssertFalse(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: URLError(.timedOut),
                attempt: 2
            )
        )
        XCTAssertFalse(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: OfficialApplicationUpdateInstallerError.invalidRedirect,
                attempt: 1
            )
        )
        XCTAssertFalse(
            OfficialApplicationUpdateInstaller.shouldRetryDownload(
                error: URLError(.cancelled),
                attempt: 1
            )
        )
    }

    func testOfficialDownloadRetryRunsSecondAttemptAndStopsAtTheBound() async throws {
        let counter = DownloadAttemptCounter()
        let noSleep: @Sendable (UInt64) async throws -> Void = { _ in }

        let value = try await OfficialApplicationUpdateInstaller.retryingDownload(
            operation: { attempt in
                await counter.record()
                if attempt == 1 {
                    throw URLError(.networkConnectionLost)
                }
                return "downloaded"
            },
            sleep: noSleep
        )

        XCTAssertEqual(value, "downloaded")
        let successfulAttempts = await counter.value()
        XCTAssertEqual(successfulAttempts, 2)

        await counter.reset()
        do {
            _ = try await OfficialApplicationUpdateInstaller.retryingDownload(
                operation: { _ in
                    await counter.record()
                    throw OfficialApplicationUpdateInstallerError.transientResponse(statusCode: 503)
                },
                sleep: noSleep
            )
            XCTFail("A persistent transient failure must stop after the retry bound")
        } catch {
            // Expected after exactly two attempts.
        }
        let persistentFailureAttempts = await counter.value()
        XCTAssertEqual(persistentFailureAttempts, 2)

        await counter.reset()
        do {
            _ = try await OfficialApplicationUpdateInstaller.retryingDownload(
                operation: { _ in
                    await counter.record()
                    throw OfficialApplicationUpdateInstallerError.invalidRedirect
                },
                sleep: noSleep
            )
            XCTFail("A redirect violation must not be retried")
        } catch {
            // Expected after one attempt.
        }
        let rejectedRedirectAttempts = await counter.value()
        XCTAssertEqual(rejectedRedirectAttempts, 1)
    }

    func testStagedArtifactDigestAndSizeRejectPostStageTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-StagedArtifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Example.zip")
        let original = Data("original package bytes".utf8)
        try original.write(to: packageURL, options: .atomic)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let stage = OfficialApplicationUpdateStage(
            applicationID: "fixture",
            workingDirectory: root,
            packageURL: packageURL,
            packageType: .zipArchive,
            downloadURL: try XCTUnwrap(URL(string: "https://downloads.example.com/Example.zip")),
            byteCount: Int64(original.count),
            sha256: digest
        )

        XCTAssertTrue(try OfficialApplicationUpdateInstaller.stagedArtifactMatches(stage))
        try Data("tampered package bytes".utf8).write(to: packageURL, options: .atomic)
        XCTAssertFalse(try OfficialApplicationUpdateInstaller.stagedArtifactMatches(stage))
    }

    func testSignedRegistryAcceptsValidSignatureAndIdentityBoundEntry() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let signingKey = try testSigningKey()
        let payload = makePayload(sequence: 7, now: now)
        let envelope = try signedEnvelope(payload: payload, keyID: "test-key", key: signingKey)
        let loader = SignedRegistryLoader(
            trustedPublicKeys: ["test-key": signingKey.publicKey.rawRepresentation]
        )

        let outcome = try loader.load(envelopeData: envelope, now: now)

        XCTAssertEqual(outcome.disposition, .acceptedRemote)
        XCTAssertNil(outcome.remoteRejection)
        XCTAssertEqual(outcome.snapshot.payload.sequence, 7)
        XCTAssertEqual(outcome.snapshot.payload.entries.first?.bundleIdentifier, "com.example.app")
    }

    func testSignedRegistryRejectsInvalidSignature() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let signingKey = try testSigningKey()
        let payloadData = try encodePayload(makePayload(sequence: 1, now: now))
        let envelope = SignedOfficialSourceRegistry(
            payload: payloadData,
            signature: Data(repeating: 0, count: 64),
            keyID: "test-key"
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        let loader = SignedRegistryLoader(
            trustedPublicKeys: ["test-key": signingKey.publicKey.rawRepresentation]
        )

        XCTAssertThrowsError(try loader.verify(envelopeData: envelopeData, now: now)) { error in
            XCTAssertEqual(error as? SignedRegistryLoadError, .invalidSignature)
        }
    }

    func testSignedRegistryRejectsExpiredPayload() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let signingKey = try testSigningKey()
        let expired = OfficialSourceRegistryPayload(
            schemaVersion: 1,
            sequence: 2,
            issuedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(-24 * 60 * 60),
            keyID: "test-key",
            entries: [makeEntry()]
        )
        let envelope = try signedEnvelope(payload: expired, keyID: "test-key", key: signingKey)
        let loader = SignedRegistryLoader(
            trustedPublicKeys: ["test-key": signingKey.publicKey.rawRepresentation]
        )

        XCTAssertThrowsError(try loader.verify(envelopeData: envelope, now: now)) { error in
            XCTAssertEqual(error as? SignedRegistryLoadError, .expired)
        }
    }

    func testSignedRegistryRollbackRetainsLastKnownGoodSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let signingKey = try testSigningKey()
        let lastKnownGoodPayload = makePayload(sequence: 10, now: now)
        let lastKnownGood = OfficialSourceRegistrySnapshot(
            payload: lastKnownGoodPayload,
            verifiedAt: now.addingTimeInterval(-60),
            isExpired: false
        )
        let olderEnvelope = try signedEnvelope(
            payload: makePayload(sequence: 9, now: now),
            keyID: "test-key",
            key: signingKey
        )
        let loader = SignedRegistryLoader(
            trustedPublicKeys: ["test-key": signingKey.publicKey.rawRepresentation]
        )

        let outcome = try loader.load(
            envelopeData: olderEnvelope,
            lastKnownGood: lastKnownGood,
            now: now
        )

        XCTAssertEqual(outcome.disposition, .retainedLastKnownGood)
        XCTAssertEqual(outcome.remoteRejection, .replayedSequence)
        XCTAssertEqual(outcome.snapshot.payload.sequence, 10)
    }

    func testRegistryRejectsSequenceRollbackAfterInstallation() async throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let registry = OfficialSourceRegistry(
            builtInEntries: [],
            userStore: InMemoryUserConfirmedSourceStore()
        )
        let current = OfficialSourceRegistrySnapshot(
            payload: makePayload(sequence: 4, now: now),
            verifiedAt: now,
            isExpired: false
        )
        let older = OfficialSourceRegistrySnapshot(
            payload: makePayload(sequence: 3, now: now),
            verifiedAt: now,
            isExpired: false
        )

        try await registry.installVerifiedSnapshot(current, now: now)
        do {
            try await registry.installVerifiedSnapshot(older, now: now)
            XCTFail("Expected registry rollback rejection")
        } catch {
            XCTAssertEqual(error as? OfficialSourceRegistryError, .expiredOrUnverifiedSnapshot)
        }
    }

    func testUserConfirmedWebsiteRemainsOpenOnlyTrust() async throws {
        let application = AppUpdateTestFixtures.application()
        let registry = OfficialSourceRegistry(
            builtInEntries: [],
            userStore: InMemoryUserConfirmedSourceStore()
        )

        try await registry.confirmWebsite(
            for: application,
            homepageURL: try XCTUnwrap(URL(string: "https://example.com")),
            updatePageURL: try XCTUnwrap(URL(string: "https://example.com/download"))
        )
        let resolvedSource = await registry.source(for: application)
        let source = try XCTUnwrap(resolvedSource)

        XCTAssertEqual(source.trustLevel, .userConfirmed)
        XCTAssertEqual(source.capability, .manualWebsite)
        XCTAssertFalse(source.canAutomaticallyDownload)
        XCTAssertFalse(source.canAutomaticallyInstall)
    }

    func testUserConfirmedWebsiteWithoutReleaseEvidenceDoesNotClaimAnUpdate() async throws {
        var application = AppUpdateTestFixtures.application(provider: .officialWebsite)
        application.officialSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/download"),
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .userConfirmation,
            trustLevel: .userConfirmed,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )

        let result = try await OfficialWebsiteUpdateProvider().checkForUpdate(application)

        XCTAssertEqual(result.status, .latestVersionUnknown)
        XCTAssertNil(result.availableVersion)
    }

    func testSparkleConfigurationDoesNotClaimVerifiedAppcastTrust() async throws {
        let application = AppUpdateTestFixtures.application(provider: .sparkle)
        let registry = OfficialSourceRegistry(
            builtInEntries: [],
            userStore: InMemoryUserConfirmedSourceStore()
        )

        let resolvedSource = await OfficialUpdateSourceResolver(registry: registry).resolve(application)
        let source = try XCTUnwrap(resolvedSource)

        XCTAssertEqual(source.verificationMethod, .sparkleConfiguration)
        XCTAssertEqual(source.trustLevel, .unverified)
        XCTAssertFalse(source.canAutomaticallyDownload)
    }

    func testCandidateWebsiteIsSourceUnconfirmedAndExcludedFromWebsiteCategory() {
        var application = AppUpdateTestFixtures.application(
            provider: .officialWebsite,
            status: .sourceUnconfirmed
        )
        application.officialSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: nil,
            homepageURL: URL(string: "https://candidate.example.com"),
            updatePageURL: nil,
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["candidate.example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: nil,
            expectedDesignatedRequirement: nil,
            verificationMethod: .candidateSearch,
            trustLevel: .candidate,
            lastVerifiedAt: nil,
            capability: .sourceConfirmation,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )

        XCTAssertFalse(application.hasConfirmedOfficialWebsiteSource)
        XCTAssertFalse(AppUpdateListFilter.websiteDownload.includes(application))
        XCTAssertTrue(AppUpdateListFilter.sourceUnconfirmed.includes(application))
    }

    func testWebsiteFilterUsesTheSinglePrimaryOfficialWebsiteProvider() {
        var application = AppUpdateTestFixtures.application(
            provider: .officialWebsite,
            status: .websiteUpdateRequired
        )
        application.officialSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialManifest,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/update"),
            releaseFeedURL: nil,
            directDownloadURL: URL(string: "https://example.com/app.zip"),
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .assistedInstaller,
            expectedPackageExtensions: ["zip"],
            officialGitHubRepository: nil
        )

        XCTAssertTrue(application.officialSource?.canAutomaticallyDownload == true)
        XCTAssertTrue(application.hasConfirmedOfficialWebsiteSource)
        XCTAssertTrue(AppUpdateListFilter.websiteDownload.includes(application))

        application.updateStatus = .officialInstallerAvailable
        XCTAssertTrue(AppUpdateListFilter.websiteDownload.includes(application))
    }

    func testBundledSelfSourceUsesTheSignedAppTeamIdentifier() async throws {
        let application = AppUpdateTestFixtures.application(
            name: "存储清理助手",
            bundleIdentifier: "com.local.StorageCleanerMac",
            path: "/Applications/存储清理助手.app",
            signingTeamIdentifier: "T9GZL52H8R",
            codeSigningIdentifier: "com.local.StorageCleanerMac",
            sourceEvidence: ["valid-code-signature"]
        )
        let registry = OfficialSourceRegistry(
            userStore: InMemoryUserConfirmedSourceStore()
        )

        let sourceValue = await registry.source(for: application)
        let source = try XCTUnwrap(sourceValue)

        XCTAssertEqual(source.expectedTeamIdentifier, "T9GZL52H8R")
        XCTAssertEqual(source.trustLevel, .verified)
        XCTAssertEqual(source.providerType, .officialGitHubRelease)
    }

    func testBundledGitHubDMGSourcesRequireExactBundleAndTeamIdentity() async throws {
        let registry = OfficialSourceRegistry(
            userStore: InMemoryUserConfirmedSourceStore()
        )
        let expected: [(bundle: String, team: String, repository: String)] = [
            ("com.jgraph.drawio.desktop", "UZEUFB4N53", "jgraph/drawio-desktop"),
            ("com.ccswitch.desktop", "R8UR22V2F9", "farion1231/cc-switch"),
        ]

        for item in expected {
            let application = AppUpdateTestFixtures.application(
                bundleIdentifier: item.bundle,
                signingTeamIdentifier: item.team,
                sourceEvidence: ["valid-code-signature"]
            )
            let sourceValue = await registry.source(for: application)
            let source = try XCTUnwrap(sourceValue)

            XCTAssertEqual(source.expectedBundleIdentifier, item.bundle)
            XCTAssertEqual(source.expectedTeamIdentifier, item.team)
            XCTAssertEqual(source.officialGitHubRepository, item.repository)
            XCTAssertEqual(source.providerType, .officialGitHubRelease)
            XCTAssertEqual(source.capability, .automatic)
            XCTAssertEqual(source.expectedPackageExtensions, ["dmg"])
            XCTAssertNil(source.directDownloadURL)
            XCTAssertTrue(source.usesDynamicGitHubReleaseAsset)
            XCTAssertTrue(source.canAutomaticallyDownload)
            XCTAssertTrue(source.canAutomaticallyInstall)

            let wrongTeam = AppUpdateTestFixtures.application(
                bundleIdentifier: item.bundle,
                signingTeamIdentifier: "WRONGTEAM1",
                sourceEvidence: ["valid-code-signature"]
            )
            let wrongTeamSource = await registry.source(for: wrongTeam)
            XCTAssertNil(wrongTeamSource)
        }
    }

    func testTrustedGitHubDynamicDMGCanJoinAutomaticPlanWithoutStaticReleaseURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubDynamicDMGPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var application = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.jgraph.drawio.desktop",
            path: root.appendingPathComponent("draw.io.app", isDirectory: true).path,
            availableVersion: "2.0",
            signingTeamIdentifier: "UZEUFB4N53",
            provider: .officialWebsite,
            status: .automaticallyUpdatable,
            sourceEvidence: ["valid-code-signature"],
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let registry = OfficialSourceRegistry(
            userStore: InMemoryUserConfirmedSourceStore()
        )
        let sourceValue = await registry.source(for: application)
        application.officialSource = try XCTUnwrap(sourceValue)
        application.updateCapability = .automatic

        let inspection = try await OfficialWebsiteUpdateProvider().inspect(application)
        let plan = ApplicationUpdatePlanBuilder().build(applications: [application])

        XCTAssertTrue(inspection.canAutomaticallyUpdate)
        XCTAssertEqual(plan.automaticApplicationIDs, [application.id])
        XCTAssertTrue(plan.websiteApplicationIDs.isEmpty)
    }

    func testReleaseOfficialSourceEnvelopeVerifiesAndUsesPublicUpdatesRepository() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let envelopeURL = repositoryRoot
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("official-sources-v1.json", isDirectory: false)
        let envelope = try Data(contentsOf: envelopeURL)
        let configuration = try XCTUnwrap(OfficialSourceRegistryRemoteConfiguration.production)
        let loader = SignedRegistryLoader(
            trustedPublicKeys: [configuration.keyID: configuration.publicKey]
        )

        let snapshot = try loader.verify(
            envelopeData: envelope,
            now: ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z")!
        )

        XCTAssertEqual(snapshot.payload.sequence, 1)
        XCTAssertEqual(
            snapshot.payload.entries.first?.officialGitHubRepository,
            "yangyihang96/StorageCleanerMacUpdates"
        )
        XCTAssertEqual(
            snapshot.payload.entries.first?.signingTeamIdentifier,
            "T9GZL52H8R"
        )
    }

    func testRegistryDoesNotBindOfficialSourceWithoutValidSignatureEvidence() async throws {
        let unsigned = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.app"
        )
        let signed = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.app",
            sourceEvidence: ["valid-code-signature"]
        )
        let registry = OfficialSourceRegistry(
            builtInEntries: [makeEntry()],
            userStore: InMemoryUserConfirmedSourceStore()
        )

        let unsignedSource = await registry.source(for: unsigned)
        let signedSource = await registry.source(for: signed)
        XCTAssertNil(unsignedSource)
        XCTAssertNotNil(signedSource)
    }

    func testRegistryRequiresEveryDeclaredSigningIdentityFieldToMatch() async throws {
        let mismatchedCodeIdentifier = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.other-target",
            sourceEvidence: ["valid-code-signature"]
        )
        let registry = OfficialSourceRegistry(
            builtInEntries: [makeEntry()],
            userStore: InMemoryUserConfirmedSourceStore()
        )

        let source = await registry.source(for: mismatchedCodeIdentifier)

        XCTAssertNil(source)
    }

    func testAllowedHostRequiresHTTPSExactHostAndStandardPort() throws {
        let validator = AllowedHostValidator()
        let allowed: Set<String> = ["downloads.example.com"]

        XCTAssertNoThrow(
            try validator.validate(
                XCTUnwrap(URL(string: "https://downloads.example.com/app.zip")),
                allowedHosts: allowed
            )
        )
        XCTAssertThrowsError(
            try validator.validate(
                XCTUnwrap(URL(string: "http://downloads.example.com/app.zip")),
                allowedHosts: allowed
            )
        ) { XCTAssertEqual($0 as? OfficialURLValidationError, .unsupportedScheme) }
        XCTAssertThrowsError(
            try validator.validate(
                XCTUnwrap(URL(string: "https://cdn.downloads.example.com/app.zip")),
                allowedHosts: allowed
            )
        ) { XCTAssertEqual($0 as? OfficialURLValidationError, .hostNotAllowed("cdn.downloads.example.com")) }
        XCTAssertThrowsError(
            try validator.validate(
                XCTUnwrap(URL(string: "https://downloads.example.com:8443/app.zip")),
                allowedHosts: allowed
            )
        ) { XCTAssertEqual($0 as? OfficialURLValidationError, .unexpectedPort) }
    }

    func testAllowedHostRejectsCredentialsAndIPAddress() throws {
        let validator = AllowedHostValidator()
        XCTAssertThrowsError(
            try validator.validate(
                XCTUnwrap(URL(string: "https://user:pass@example.com/app.zip")),
                allowedHosts: ["example.com"]
            )
        ) { XCTAssertEqual($0 as? OfficialURLValidationError, .containsCredentials) }

        XCTAssertThrowsError(try AllowedHostValidator.normalizedHost("127.0.0.1")) { error in
            XCTAssertEqual(error as? OfficialURLValidationError, .localOrIPAddressHost)
        }
    }

    func testRedirectValidatorChecksEveryHop() throws {
        let validator = RedirectValidator()
        let initial = try XCTUnwrap(URL(string: "https://downloads.example.com/app.zip"))
        let tracking = try XCTUnwrap(URL(string: "https://tracking.example.net/redirect"))
        let final = try XCTUnwrap(URL(string: "https://cdn.example.com/app.zip"))

        XCTAssertThrowsError(
            try validator.validate(
                chain: [initial, tracking, final],
                allowedHosts: ["downloads.example.com", "cdn.example.com"]
            )
        ) { error in
            XCTAssertEqual(error as? OfficialURLValidationError, .hostNotAllowed("tracking.example.net"))
        }
    }

    func testAppUpdateServiceValidatesOfficialWebsiteBeforeOpening() throws {
        var application = AppUpdateTestFixtures.application(
            id: "official-open",
            provider: .officialWebsite,
            status: .websiteUpdateRequired
        )
        let trustedSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://downloads.example.com/update"),
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["downloads.example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .userConfirmation,
            trustLevel: .userConfirmed,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
        application.officialSource = trustedSource

        XCTAssertEqual(
            AppUpdateService.validatedOfficialWebsiteURL(for: application),
            URL(string: "https://downloads.example.com/update")
        )
        XCTAssertEqual(
            AppUpdateService.validatedManualUpdateURL(for: application),
            URL(string: "https://downloads.example.com/update")
        )

        application.officialSource = OfficialUpdateSource(
            applicationIdentity: trustedSource.applicationIdentity,
            providerType: trustedSource.providerType,
            developerName: trustedSource.developerName,
            homepageURL: trustedSource.homepageURL,
            updatePageURL: URL(string: "https://evil.example.net/update"),
            releaseFeedURL: trustedSource.releaseFeedURL,
            directDownloadURL: trustedSource.directDownloadURL,
            allowedHosts: trustedSource.allowedHosts,
            expectedBundleIdentifier: trustedSource.expectedBundleIdentifier,
            expectedTeamIdentifier: trustedSource.expectedTeamIdentifier,
            expectedDesignatedRequirement: trustedSource.expectedDesignatedRequirement,
            verificationMethod: trustedSource.verificationMethod,
            trustLevel: trustedSource.trustLevel,
            lastVerifiedAt: trustedSource.lastVerifiedAt,
            capability: trustedSource.capability,
            expectedPackageExtensions: trustedSource.expectedPackageExtensions,
            officialGitHubRepository: trustedSource.officialGitHubRepository
        )

        XCTAssertNil(AppUpdateService.validatedOfficialWebsiteURL(for: application))
        XCTAssertNil(AppUpdateService.validatedManualUpdateURL(for: application))
    }

    func testManualHomebrewUpdateUsesOnlyProviderVerifiedAllowedURL() throws {
        var application = AppUpdateTestFixtures.application(
            id: "homebrew-manual-link",
            provider: .homebrew,
            status: .updateAvailable
        )
        let updateURL = try XCTUnwrap(URL(string: "https://example.com/releases"))
        application.officialSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .homebrew,
            developerName: nil,
            homepageURL: updateURL,
            updatePageURL: updateURL,
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .homebrewMetadata,
            trustLevel: .providerVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )

        XCTAssertEqual(AppUpdateService.validatedManualUpdateURL(for: application), updateURL)

        application.bundleIdentifier = "com.example.replaced"
        XCTAssertNil(AppUpdateService.validatedManualUpdateURL(for: application))
    }

    func testArchiveValidatorAcceptsContainedPathsAndSymlinks() throws {
        let entries = [
            ArchiveEntryDescriptor(
                path: "Example.app/Contents/MacOS/Example",
                kind: .file,
                compressedSize: 100,
                uncompressedSize: 200
            ),
            ArchiveEntryDescriptor(
                path: "Example.app/Contents/MacOS/FrameworksLink",
                kind: .symbolicLink,
                compressedSize: 1,
                uncompressedSize: 1,
                symbolicLinkTarget: "../Frameworks"
            ),
        ]

        XCTAssertNoThrow(try ArchiveExtractionValidator().validate(entries: entries))
    }

    func testArchiveValidatorRejectsTraversalAbsoluteAndEscapingSymlink() {
        let validator = ArchiveExtractionValidator()
        XCTAssertThrowsError(try validator.validateRelativePath("Example.app/../../evil"))
        XCTAssertThrowsError(try validator.validateRelativePath("/tmp/evil"))
        XCTAssertThrowsError(try validator.validateRelativePath("C:/evil"))

        let escaping = ArchiveEntryDescriptor(
            path: "Example.app/Contents/link",
            kind: .symbolicLink,
            compressedSize: 1,
            uncompressedSize: 1,
            symbolicLinkTarget: "../../../outside"
        )
        XCTAssertThrowsError(try validator.validate(entries: [escaping])) { error in
            guard case .escapingSymbolicLink = error as? PackageValidationError else {
                return XCTFail("Expected escapingSymbolicLink, got \(error)")
            }
        }
    }

    func testArchiveValidatorRejectsZipBombRatio() {
        let entry = ArchiveEntryDescriptor(
            path: "Example.app/Contents/large.bin",
            kind: .file,
            compressedSize: 1,
            uncompressedSize: 2_000
        )

        XCTAssertThrowsError(try ArchiveExtractionValidator().validate(entries: [entry])) { error in
            XCTAssertEqual(error as? PackageValidationError, .suspiciousCompressionRatio)
        }
    }

    func testVerifiedOfficialDMGAndSingleAppZIPCanJoinAutomaticPlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialDMGPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var application = AppUpdateTestFixtures.application(
            path: root.appendingPathComponent("Example.app").path,
            availableVersion: "2.0",
            provider: .officialWebsite,
            status: .automaticallyUpdatable,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let source = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialManifest,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/download"),
            releaseFeedURL: URL(string: "https://example.com/releases.json"),
            directDownloadURL: URL(string: "https://downloads.example.com/Example.dmg"),
            allowedHosts: ["example.com", "downloads.example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .automatic,
            expectedPackageExtensions: ["dmg"],
            officialGitHubRepository: nil
        )
        application.officialSource = source
        application.updateCapability = .automatic

        let inspected = try await OfficialWebsiteUpdateProvider().inspect(application)
        let plan = ApplicationUpdatePlanBuilder().build(applications: [application])
        let oneClickPlan = AppUpdateService.oneClickPlan(for: [application])

        XCTAssertTrue(inspected.canAutomaticallyUpdate)
        XCTAssertEqual(plan.automaticApplicationIDs, [application.id])
        XCTAssertTrue(plan.websiteApplicationIDs.isEmpty)
        XCTAssertEqual(oneClickPlan.automaticApps.map(\.id), [application.id])
        XCTAssertEqual(oneClickPlan.automaticCount, 1)
        XCTAssertTrue(oneClickPlan.manualApps.isEmpty)
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(
            application,
            hostBundleIdentifier: application.bundleIdentifier,
            hostBundleURL: URL(fileURLWithPath: "/Applications/Other.app")
        ))
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(
            application,
            hostBundleIdentifier: nil,
            hostBundleURL: application.bundleURL
        ))

        let archiveSource = OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialManifest,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/download"),
            releaseFeedURL: URL(string: "https://example.com/releases.json"),
            directDownloadURL: URL(string: "https://downloads.example.com/Example.zip"),
            allowedHosts: ["example.com", "downloads.example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .automatic,
            expectedPackageExtensions: ["zip"],
            officialGitHubRepository: nil
        )
        application.officialSource = archiveSource

        let archiveInspection = try await OfficialWebsiteUpdateProvider().inspect(application)
        let archivePlan = ApplicationUpdatePlanBuilder().build(applications: [application])

        XCTAssertTrue(archiveInspection.canAutomaticallyUpdate)
        XCTAssertEqual(archivePlan.automaticApplicationIDs, [application.id])
        XCTAssertTrue(archivePlan.websiteApplicationIDs.isEmpty)
    }

    func testOfficialApplicationReplacementRollsBackFailedVerification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialReplacement-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Example.app", isDirectory: true)
        let staged = root.appendingPathComponent("Staged.app", isDirectory: true)
        let transactionURL = root.appendingPathComponent("replacement.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try OfficialApplicationReplacement.replace(
                destination: destination,
                staged: staged,
                expectedIdentity: ApplicationIdentity(
                    bundleIdentifier: "com.example.app",
                    signingTeamIdentifier: "TEAM123",
                    codeSigningIdentifier: "com.example.app"
                ),
                originalVersion: ApplicationVersion(marketing: "1.0"),
                targetVersion: ApplicationVersion(marketing: "2.0"),
                transactionURL: transactionURL
            ) { _ in
                throw CocoaError(.fileReadCorruptFile)
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("marker")),
            Data("old".utf8)
        )
    }

    func testOfficialApplicationReplacementCommitsVerifiedUpdateAndCleansTransaction() throws {
        let fixture = try makeReplacementRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try OfficialApplicationReplacement.replace(
            destination: fixture.destination,
            staged: fixture.staged,
            expectedIdentity: fixture.identity,
            originalVersion: fixture.oldVersion,
            targetVersion: fixture.targetVersion,
            transactionURL: fixture.transactionURL
        ) { destination in
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent("marker")),
                Data("new".utf8)
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("marker")),
            Data("new".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: fixture.root,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".StorageCleanerMac-Backup-") }
        )
    }

    func testOfficialReplacementRecoveryRestoresAfterOldMovedToBackupCrash() throws {
        let fixture = try makeReplacementRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.moveItem(at: fixture.destination, to: fixture.backup)
        try OfficialApplicationReplacementTransactionStore(fileURL: fixture.transactionURL).save(
            fixture.transaction(.destinationMovedToBackup)
        )
        let transactionAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.transactionURL.path
        )
        let transactionMode = try XCTUnwrap(
            transactionAttributes[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(transactionMode & 0o077, 0)

        let result = try OfficialApplicationReplacement.reconcilePending(
            transactionURL: fixture.transactionURL,
            identityVerifier: fixture.identityVerifier
        )

        XCTAssertEqual(result, .restoredOriginal)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("marker")),
            Data("old".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
    }

    func testOfficialReplacementRecoveryCleansBackupAfterStagedDestinationCrashAndIsIdempotent() throws {
        let fixture = try makeReplacementRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.moveItem(at: fixture.destination, to: fixture.backup)
        try FileManager.default.moveItem(at: fixture.staged, to: fixture.destination)
        try OfficialApplicationReplacementTransactionStore(fileURL: fixture.transactionURL).save(
            fixture.transaction(.stagedMovedToDestination)
        )

        let first = try OfficialApplicationReplacement.reconcilePending(
            transactionURL: fixture.transactionURL,
            identityVerifier: fixture.identityVerifier
        )
        let second = try OfficialApplicationReplacement.reconcilePending(
            transactionURL: fixture.transactionURL,
            identityVerifier: fixture.identityVerifier
        )

        XCTAssertEqual(first, .cleanedCandidate)
        XCTAssertEqual(second, .none)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("marker")),
            Data("new".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
    }

    func testOfficialReplacementRecoveryRejectsCandidateBelowFrozenTargetAndKeepsBackup() throws {
        let fixture = try makeReplacementRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try writeReplacementApp(
            fixture.staged,
            marker: "too-old",
            version: ApplicationVersion(marketing: "1.5", build: "150")
        )
        try FileManager.default.moveItem(at: fixture.destination, to: fixture.backup)
        try FileManager.default.moveItem(at: fixture.staged, to: fixture.destination)
        try OfficialApplicationReplacementTransactionStore(fileURL: fixture.transactionURL).save(
            fixture.transaction(.stagedMovedToDestination)
        )

        XCTAssertThrowsError(
            try OfficialApplicationReplacement.reconcilePending(
                transactionURL: fixture.transactionURL,
                identityVerifier: fixture.identityVerifier
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
    }

    func testOfficialReplacementRecoveryRejectsCorruptAndTamperedRecords() throws {
        let fixture = try makeReplacementRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fileManager = FileManager.default

        try Data("not-json".utf8).write(to: fixture.transactionURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.transactionURL.path)
        XCTAssertThrowsError(
            try OfficialApplicationReplacement.reconcilePending(
                transactionURL: fixture.transactionURL,
                identityVerifier: fixture.identityVerifier
            )
        )
        try? fileManager.removeItem(at: fixture.transactionURL)

        let tampered = OfficialApplicationReplacementTransaction(
            id: fixture.transactionID,
            rootURL: fixture.root,
            destinationURL: fixture.root.deletingLastPathComponent()
                .appendingPathComponent("Outside.app", isDirectory: true),
            backupURL: fixture.backup,
            stagedURL: fixture.staged,
            expectedIdentity: fixture.identity,
            originalVersion: fixture.oldVersion,
            targetVersion: fixture.targetVersion,
            phase: .destinationMovedToBackup
        )
        let data = try JSONEncoder().encode(tampered)
        try data.write(to: fixture.transactionURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.transactionURL.path)
        XCTAssertThrowsError(
            try OfficialApplicationReplacement.reconcilePending(
                transactionURL: fixture.transactionURL,
                identityVerifier: fixture.identityVerifier
            )
        )
    }

    private struct ReplacementRecoveryFixture {
        let root: URL
        let destination: URL
        let backup: URL
        let staged: URL
        let transactionURL: URL
        let transactionID: UUID
        let identity: ApplicationIdentity
        let oldVersion: ApplicationVersion
        let targetVersion: ApplicationVersion
        let transaction: (OfficialApplicationReplacementPhase) -> OfficialApplicationReplacementTransaction
        let identityVerifier: OfficialApplicationReplacement.IdentityVerifier
    }

    private func makeReplacementRecoveryFixture() throws -> ReplacementRecoveryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialReplacementRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Example.app", isDirectory: true)
        let backup = root.appendingPathComponent(
            ".StorageCleanerMac-Backup-\(UUID().uuidString).app",
            isDirectory: true
        )
        let staged = root.appendingPathComponent(
            ".StorageCleanerMac-Update-\(UUID().uuidString).app",
            isDirectory: true
        )
        let transactionURL = root.appendingPathComponent("replacement.json")
        let transactionID = UUID()
        let identity = ApplicationIdentity(
            bundleIdentifier: "com.example.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.app"
        )
        let oldVersion = ApplicationVersion(marketing: "1.0", build: "100")
        let targetVersion = ApplicationVersion(marketing: "2.0", build: "200")
        try writeReplacementApp(destination, marker: "old", version: oldVersion)
        try writeReplacementApp(
            staged,
            marker: "new",
            version: targetVersion
        )
        let transaction = { phase in
            OfficialApplicationReplacementTransaction(
                id: transactionID,
                rootURL: root,
                destinationURL: destination,
                backupURL: backup,
                stagedURL: staged,
                expectedIdentity: identity,
                originalVersion: oldVersion,
                targetVersion: targetVersion,
                phase: phase
            )
        }
        let identityVerifier: OfficialApplicationReplacement.IdentityVerifier = { url, expected in
            Bundle(url: url)?.bundleIdentifier == expected.bundleIdentifier
        }
        return ReplacementRecoveryFixture(
            root: root,
            destination: destination,
            backup: backup,
            staged: staged,
            transactionURL: transactionURL,
            transactionID: transactionID,
            identity: identity,
            oldVersion: oldVersion,
            targetVersion: targetVersion,
            transaction: transaction,
            identityVerifier: identityVerifier
        )
    }

    private func writeReplacementApp(
        _ url: URL,
        marker: String,
        version: ApplicationVersion
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleShortVersionString": version.marketing,
            "CFBundleVersion": version.build,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func testSigningKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    }

    private func makeEntry() -> OfficialSourceRegistryEntry {
        OfficialSourceRegistryEntry(
            bundleIdentifier: "com.example.app",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.app",
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com")!,
            updatePageURL: URL(string: "https://example.com/download")!,
            releaseFeedURL: URL(string: "https://example.com/releases.json")!,
            directDownloadURL: URL(string: "https://downloads.example.com/Example.zip")!,
            allowedHosts: ["example.com", "downloads.example.com"],
            expectedDesignatedRequirement: nil,
            providerType: .officialManifest,
            capability: .automatic,
            expectedPackageExtensions: ["zip"],
            officialGitHubRepository: nil,
            lastVerifiedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    private func makePayload(
        sequence: Int,
        now: Date
    ) -> OfficialSourceRegistryPayload {
        OfficialSourceRegistryPayload(
            schemaVersion: 1,
            sequence: sequence,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            keyID: "test-key",
            entries: [makeEntry()]
        )
    }

    private func encodePayload(_ payload: OfficialSourceRegistryPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private func signedEnvelope(
        payload: OfficialSourceRegistryPayload,
        keyID: String,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payloadData = try encodePayload(payload)
        let envelope = SignedOfficialSourceRegistry(
            payload: payloadData,
            signature: try key.signature(for: payloadData),
            keyID: keyID
        )
        return try JSONEncoder().encode(envelope)
    }
}

private actor DownloadAttemptCounter {
    private var attempts = 0

    func record() {
        attempts += 1
    }

    func value() -> Int {
        attempts
    }

    func reset() {
        attempts = 0
    }
}
