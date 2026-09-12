import Foundation
import Security
import XCTest
@testable import StorageCleanerMac

final class WebsiteUpdateWorkflowTests: XCTestCase {
    func testQueuePersistsAndRestoresWaitingItem() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("website-update-queue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = FileWebsiteUpdateQueueStore(
            fileURL: temporaryRoot.appendingPathComponent("queue.json", isDirectory: false)
        )
        let queue = WebsiteUpdateQueue(store: store)
        let application = websiteApplication(id: "persist")

        let created = try await queue.start(applications: [application])
        let item = try XCTUnwrap(created.items.first)
        try await queue.beginPresentation(itemID: item.id, sessionID: item.sessionID)
        try await queue.markWaitingForUser(
            itemID: item.id,
            sessionID: item.sessionID,
            detail: "waiting"
        )

        let restoredQueue = WebsiteUpdateQueue(store: store)
        let restored = try await restoredQueue.restore(applications: [application])
        let restoredItem = try XCTUnwrap(restored?.items.first)

        XCTAssertEqual(restored?.sessionID, created.sessionID)
        XCTAssertEqual(restoredItem.id, item.id)
        XCTAssertEqual(restoredItem.state, .waitingForUser)
        XCTAssertEqual(restoredItem.detail, "waiting")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent("queue.json").path
        ))
    }

    func testWorkflowDoesNotCompleteWhenInstalledVersionIsUnchanged() async throws {
        let queue = WebsiteUpdateQueue(store: InMemoryWebsiteUpdateQueueStore())
        let opener = RecordingWebsiteOpener(result: true)
        let workflow = WebsiteUpdateWorkflow(
            queue: queue,
            opener: opener,
            applicationRechecker: FixedApplicationRechecker(
                snapshot: recheckSnapshot(
                    for: websiteApplication(id: "unchanged", version: "1.0", availableVersion: "2.0"),
                    observedVersion: "1.0",
                    observedBuild: "100"
                )
            )
        )
        let application = websiteApplication(id: "unchanged", version: "1.0", availableVersion: "2.0")

        try await workflow.start(applications: [application])
        try await workflow.openCurrentWebsite()
        let result = try await workflow.recheckCurrentVersion()

        XCTAssertEqual(
            result,
            .unchanged(ApplicationVersion(marketing: "1.0", build: "100"))
        )
        let currentValue = await workflow.currentItem()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .waitingForUser)
        XCTAssertNil(current.observedVersion)
        let openedURLs = await opener.openedURLs()
        XCTAssertEqual(openedURLs, [URL(string: "https://example.com/download")!])
    }

    func testWorkflowCompletesOnlyAfterInstalledVersionIncreases() async throws {
        let queue = WebsiteUpdateQueue(store: InMemoryWebsiteUpdateQueueStore())
        let opener = RecordingWebsiteOpener(result: true)
        let workflow = WebsiteUpdateWorkflow(
            queue: queue,
            opener: opener,
            applicationRechecker: FixedApplicationRechecker(
                snapshot: recheckSnapshot(
                    for: websiteApplication(id: "upgraded", version: "1.0", availableVersion: "2.0"),
                    observedVersion: "2.0",
                    observedBuild: "200"
                )
            )
        )
        let application = websiteApplication(id: "upgraded", version: "1.0", availableVersion: "2.0")

        try await workflow.start(applications: [application])
        try await workflow.openCurrentWebsite()
        let result = try await workflow.recheckCurrentVersion()

        XCTAssertEqual(
            result,
            .updated(ApplicationVersion(marketing: "2.0", build: "200"))
        )
        let current = await workflow.currentItem()
        XCTAssertNil(current)
        let snapshotValue = await workflow.currentSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)
        let completed = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.observedVersion, ApplicationVersion(marketing: "2.0", build: "200"))
        XCTAssertEqual(completed.sourceResolutionState, .resolved)
        XCTAssertEqual(completed.versionCheckState, .upToDate)
        XCTAssertEqual(completed.updateCapability, .websiteGuided)
    }

    func testWebsiteQueuePersistsIndependentPerItemResolutionAndCapability() async throws {
        let first = websiteApplication(id: "first")
        let second = websiteApplication(id: "second")
        let queue = WebsiteUpdateQueue(store: InMemoryWebsiteUpdateQueueStore())

        let created = try await queue.start(applications: [first, second])

        XCTAssertEqual(created.items.count, 2)
        XCTAssertTrue(created.items.allSatisfy { $0.sourceResolutionState == .resolved })
        XCTAssertTrue(created.items.allSatisfy { $0.versionCheckState == .updateAvailable })
        XCTAssertTrue(created.items.allSatisfy { $0.updateCapability == .websiteGuided })

        let firstItem = try XCTUnwrap(created.items.first)
        try await queue.deferCurrent(itemID: firstItem.id, sessionID: firstItem.sessionID)
        let current = await queue.currentItem()
        XCTAssertEqual(current?.applicationID, second.id)
        XCTAssertEqual(current?.sourceResolutionState, .resolved)
        XCTAssertEqual(current?.versionCheckState, .updateAvailable)
    }

    func testWorkflowRejectsVersionIncreaseWhenObservedSignatureIsInvalid() async throws {
        let application = websiteApplication(id: "invalid-signature", version: "1.0", availableVersion: "2.0")
        let invalidSnapshot = recheckSnapshot(
            for: application,
            observedVersion: "2.0",
            observedBuild: "200",
            signatureIsValid: false
        )
        let workflow = WebsiteUpdateWorkflow(
            queue: WebsiteUpdateQueue(store: InMemoryWebsiteUpdateQueueStore()),
            opener: RecordingWebsiteOpener(result: true),
            applicationRechecker: FixedApplicationRechecker(snapshot: invalidSnapshot)
        )

        try await workflow.start(applications: [application])
        try await workflow.openCurrentWebsite()

        do {
            _ = try await workflow.recheckCurrentVersion()
            XCTFail("Expected invalid signature to block completion")
        } catch {
            XCTAssertEqual(error as? WebsiteUpdateWorkflowError, .applicationIdentityChanged)
        }
        let currentValue = await workflow.currentItem()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .waitingForUser)
        XCTAssertNil(current.observedVersion)
    }

    func testWorkflowRejectsVersionIncreaseWhenObservedIdentityChanges() async throws {
        let application = websiteApplication(id: "changed-identity", version: "1.0", availableVersion: "2.0")
        let mismatchedSnapshot = recheckSnapshot(
            for: application,
            observedVersion: "2.0",
            observedBuild: "200",
            bundleIdentifier: "com.attacker.replacement"
        )
        let workflow = WebsiteUpdateWorkflow(
            queue: WebsiteUpdateQueue(store: InMemoryWebsiteUpdateQueueStore()),
            opener: RecordingWebsiteOpener(result: true),
            applicationRechecker: FixedApplicationRechecker(snapshot: mismatchedSnapshot)
        )

        try await workflow.start(applications: [application])
        try await workflow.openCurrentWebsite()

        do {
            _ = try await workflow.recheckCurrentVersion()
            XCTFail("Expected identity mismatch to block completion")
        } catch {
            XCTAssertEqual(error as? WebsiteUpdateWorkflowError, .applicationIdentityChanged)
        }
        let currentValue = await workflow.currentItem()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .waitingForUser)
        XCTAssertNil(current.observedVersion)
    }

    func testQueueRestoreFailsClosedWhenOfficialSourceWasRevoked() async throws {
        let application = websiteApplication(id: "revoked-source")
        let store = InMemoryWebsiteUpdateQueueStore()
        let queue = WebsiteUpdateQueue(store: store)
        let created = try await queue.start(applications: [application])
        let item = try XCTUnwrap(created.items.first)
        try await queue.beginPresentation(itemID: item.id, sessionID: item.sessionID)
        try await queue.markWaitingForUser(
            itemID: item.id,
            sessionID: item.sessionID,
            detail: "waiting"
        )

        var revoked = application
        revoked.officialSource = nil
        let restored = try await WebsiteUpdateQueue(store: store).restore(applications: [revoked])
        let restoredItem = try XCTUnwrap(restored?.items.first)

        XCTAssertEqual(restoredItem.state, .failed)
        XCTAssertTrue(restoredItem.detail?.contains("official source") == true
            || restoredItem.detail?.contains("官方来源") == true)
    }

    func testGitHubReleaseAdapterUsesInjectedLoaderAndParsesOfficialRelease() async throws {
        let payload = Data(
            #"{"tag_name":"v2.4.1","published_at":"2026-07-19T10:20:30Z","body":"Security fixes"}"#.utf8
        )
        let loader = RecordingOfficialReleaseLoader(
            data: payload,
            statusCode: 200
        )
        let adapter = OfficialGitHubReleaseAdapter(loader: loader)
        let application = websiteApplication(id: "github")
        let source = githubSource(for: application)

        let release = try await adapter.latestRelease(for: source)

        XCTAssertTrue(adapter.supports(source))
        XCTAssertEqual(release?.version, ApplicationVersion(marketing: "2.4.1"))
        XCTAssertEqual(release?.releaseNotes, "Security fixes")
        XCTAssertNotNil(release?.releaseDate)
        XCTAssertNil(release?.downloadURL)
        let requests = await loader.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://api.github.com/repos/example-owner/example-app/releases/latest"
        )
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testGitHubReleaseAdapterPrefersCurrentArchitectureAndReadsAssetIntegrity() async throws {
        let armDigest = "sha256:\(String(repeating: "a", count: 64))"
        let x64Digest = "sha256:\(String(repeating: "b", count: 64))"
        let universalDigest = "sha256:\(String(repeating: "c", count: 64))"
        let payload = Data(
            """
            {
              "tag_name": "v2.5.0",
              "assets": [
                {
                  "name": "Example-x64.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.5.0/Example-x64.dmg",
                  "size": 220,
                  "digest": "\(x64Digest)"
                },
                {
                  "name": "Example-universal.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.5.0/Example-universal.dmg",
                  "size": 330,
                  "digest": "\(universalDigest)"
                },
                {
                  "name": "Example-arm64.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.5.0/Example-arm64.dmg",
                  "size": 110,
                  "digest": "\(armDigest)"
                }
              ]
            }
            """.utf8
        )
        let loader = RecordingOfficialReleaseLoader(data: payload, statusCode: 200)
        let source = githubSource(for: websiteApplication(id: "github-architecture"))

        let armRelease = try await OfficialGitHubReleaseAdapter(
            loader: loader,
            architecture: .arm64
        ).latestRelease(for: source)
        let x64Release = try await OfficialGitHubReleaseAdapter(
            loader: loader,
            architecture: .x64
        ).latestRelease(for: source)

        XCTAssertEqual(armRelease?.downloadURL?.lastPathComponent, "Example-arm64.dmg")
        XCTAssertEqual(armRelease?.downloadSize, 110)
        XCTAssertEqual(armRelease?.checksumSHA256, armDigest)
        XCTAssertEqual(x64Release?.downloadURL?.lastPathComponent, "Example-x64.dmg")
        XCTAssertEqual(x64Release?.downloadSize, 220)
        XCTAssertEqual(x64Release?.checksumSHA256, x64Digest)

        var application = websiteApplication(id: "github-resolver")
        application.officialSource = source
        let resolved = try OfficialDownloadResolver().resolve(
            for: application,
            release: try XCTUnwrap(armRelease)
        )
        XCTAssertEqual(resolved.packageType, .diskImage)
        XCTAssertEqual(resolved.expectedSize, 110)
        XCTAssertEqual(resolved.checksumSHA256, armDigest)
        XCTAssertTrue(resolved.permitsAutomaticInstallation)
    }

    func testGitHubReleaseAdapterFallsBackToArchitectureNeutralMacOSDMG() async throws {
        let digest = "sha256:\(String(repeating: "d", count: 64))"
        let payload = Data(
            """
            {
              "tag_name": "v3.19.1",
              "assets": [
                {
                  "name": "CC-Switch-v3.19.1-Windows-arm64.msi",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v3.19.1/CC-Switch-v3.19.1-Windows-arm64.msi",
                  "size": 100,
                  "digest": "\(digest)"
                },
                {
                  "name": "CC-Switch-v3.19.1-macOS.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v3.19.1/CC-Switch-v3.19.1-macOS.dmg",
                  "size": 27019362,
                  "digest": "\(digest)"
                }
              ]
            }
            """.utf8
        )
        let adapter = OfficialGitHubReleaseAdapter(
            loader: RecordingOfficialReleaseLoader(data: payload, statusCode: 200),
            architecture: .arm64
        )

        let release = try await adapter.latestRelease(
            for: githubSource(for: websiteApplication(id: "github-universal"))
        )

        XCTAssertEqual(release?.downloadURL?.lastPathComponent, "CC-Switch-v3.19.1-macOS.dmg")
        XCTAssertEqual(release?.downloadSize, 27_019_362)
        XCTAssertEqual(release?.checksumSHA256, digest)
    }

    func testGitHubReleaseAdapterRejectsAmbiguousArchitectureAssets() async throws {
        let digest = "sha256:\(String(repeating: "e", count: 64))"
        let payload = Data(
            """
            {
              "tag_name": "v2.5.0",
              "assets": [
                {
                  "name": "Example-arm64.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.5.0/Example-arm64.dmg",
                  "size": 100,
                  "digest": "\(digest)"
                },
                {
                  "name": "Example-aarch64.dmg",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.5.0/Example-aarch64.dmg",
                  "size": 100,
                  "digest": "\(digest)"
                }
              ]
            }
            """.utf8
        )
        let adapter = OfficialGitHubReleaseAdapter(
            loader: RecordingOfficialReleaseLoader(data: payload, statusCode: 200),
            architecture: .arm64
        )

        do {
            _ = try await adapter.latestRelease(
                for: githubSource(for: websiteApplication(id: "github-ambiguous"))
            )
            XCTFail("Expected ambiguous architecture assets to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OfficialGitHubReleaseAdapterError,
                .ambiguousMacDiskImages
            )
        }
    }

    func testGitHubReleaseAdapterRejectsAssetOutsideAllowedHosts() async throws {
        let digest = "sha256:\(String(repeating: "f", count: 64))"
        let payload = Data(
            """
            {
              "tag_name": "v2.5.0",
              "assets": [
                {
                  "name": "Example-arm64.dmg",
                  "browser_download_url": "https://downloads.example.com/Example-arm64.dmg",
                  "size": 100,
                  "digest": "\(digest)"
                }
              ]
            }
            """.utf8
        )
        let adapter = OfficialGitHubReleaseAdapter(
            loader: RecordingOfficialReleaseLoader(data: payload, statusCode: 200),
            architecture: .arm64
        )

        do {
            _ = try await adapter.latestRelease(
                for: githubSource(for: websiteApplication(id: "github-asset-host"))
            )
            XCTFail("Expected a non-allowlisted asset host to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OfficialURLValidationError,
                .hostNotAllowed("downloads.example.com")
            )
        }
    }

    func testGitHubReleaseAdapterDoesNotLoadInvalidRepository() async throws {
        let loader = RecordingOfficialReleaseLoader(data: Data(), statusCode: 200)
        let adapter = OfficialGitHubReleaseAdapter(loader: loader)
        let application = websiteApplication(id: "invalid-repository")
        var source = githubSource(for: application)
        source = OfficialUpdateSource(
            applicationIdentity: source.applicationIdentity,
            providerType: source.providerType,
            developerName: source.developerName,
            homepageURL: source.homepageURL,
            updatePageURL: source.updatePageURL,
            releaseFeedURL: source.releaseFeedURL,
            directDownloadURL: source.directDownloadURL,
            allowedHosts: source.allowedHosts,
            expectedBundleIdentifier: source.expectedBundleIdentifier,
            expectedTeamIdentifier: source.expectedTeamIdentifier,
            expectedDesignatedRequirement: source.expectedDesignatedRequirement,
            verificationMethod: source.verificationMethod,
            trustLevel: source.trustLevel,
            lastVerifiedAt: source.lastVerifiedAt,
            capability: source.capability,
            expectedPackageExtensions: source.expectedPackageExtensions,
            officialGitHubRepository: "example-owner/example-app/extra"
        )

        let release = try await adapter.latestRelease(for: source)

        XCTAssertNil(release)
        let requests = await loader.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testGitHubReleaseAdapterRejectsNonGitHubFinalResponseURL() async throws {
        let payload = Data(#"{"tag_name":"v2.4.1"}"#.utf8)
        let loader = RecordingOfficialReleaseLoader(
            data: payload,
            statusCode: 200,
            responseURL: URL(string: "https://redirect.example.com/releases/latest")
        )
        let adapter = OfficialGitHubReleaseAdapter(loader: loader)
        let source = githubSource(for: websiteApplication(id: "github-final-host"))

        do {
            _ = try await adapter.latestRelease(for: source)
            XCTFail("Expected a non-GitHub final response URL to be rejected")
        } catch let error as OfficialURLValidationError {
            XCTAssertEqual(error, .hostNotAllowed("redirect.example.com"))
        }
    }

    private func websiteApplication(
        id: String,
        version: String = "1.0",
        availableVersion: String? = "2.0"
    ) -> InstalledApplication {
        var application = AppUpdateTestFixtures.application(
            id: id,
            version: version,
            availableVersion: availableVersion,
            provider: .officialWebsite,
            status: .websiteUpdateRequired
        )
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
        return application
    }

    private func githubSource(for application: InstalledApplication) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialGitHubRelease,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://github.com/example-owner/example-app"),
            updatePageURL: URL(string: "https://github.com/example-owner/example-app/releases"),
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: OfficialGitHubRepositoryPolicy.assetDownloadHosts,
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .automatic,
            expectedPackageExtensions: ["dmg"],
            officialGitHubRepository: "example-owner/example-app"
        )
    }

    private func recheckSnapshot(
        for original: InstalledApplication,
        observedVersion: String,
        observedBuild: String,
        signatureIsValid: Bool = true,
        bundleIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        codeSigningIdentifier: String? = nil
    ) -> InstalledApplicationRecheckSnapshot {
        var observed = AppUpdateTestFixtures.application(
            id: original.id,
            name: original.displayName,
            bundleIdentifier: bundleIdentifier ?? original.bundleIdentifier,
            path: original.bundleURL.path,
            version: observedVersion,
            build: observedBuild,
            signingTeamIdentifier: teamIdentifier ?? original.signingTeamIdentifier,
            codeSigningIdentifier: codeSigningIdentifier ?? original.codeSigningIdentifier,
            sourceEvidence: signatureIsValid ? ["valid-code-signature"] : []
        )
        observed.officialSource = original.officialSource
        return InstalledApplicationRecheckSnapshot(
            application: observed,
            signature: CodeSignatureVerificationResult(
                isValid: signatureIsValid,
                codeSigningIdentifier: codeSigningIdentifier ?? original.codeSigningIdentifier,
                teamIdentifier: teamIdentifier ?? original.signingTeamIdentifier,
                designatedRequirement: nil,
                certificateCommonNames: [],
                status: signatureIsValid ? errSecSuccess : errSecCSUnsigned
            )
        )
    }
}

private actor RecordingWebsiteOpener: WebsiteUpdatePageOpening {
    private let result: Bool
    private var recordedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        recordedURLs.append(url)
        return result
    }

    func openedURLs() -> [URL] { recordedURLs }
}

private struct FixedApplicationRechecker: InstalledApplicationRechecking {
    let snapshot: InstalledApplicationRecheckSnapshot?

    func snapshot(at applicationURL: URL) async throws -> InstalledApplicationRecheckSnapshot? {
        snapshot
    }
}

private actor RecordingOfficialReleaseLoader: OfficialReleaseDataLoading {
    private let data: Data
    private let statusCode: Int
    private let responseURL: URL?
    private var recordedRequests: [URLRequest] = []

    init(data: Data, statusCode: Int, responseURL: URL? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.responseURL = responseURL
    }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let response = HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    func requests() -> [URLRequest] { recordedRequests }
}
