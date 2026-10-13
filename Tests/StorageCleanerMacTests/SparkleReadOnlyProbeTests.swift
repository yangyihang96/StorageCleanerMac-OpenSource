import Foundation
import XCTest
@testable import StorageCleanerMac

final class SparkleReadOnlyProbeTests: XCTestCase {
    func testMetadataPersistsOnlyBundleDeclaredSafeConfiguration() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = ApplicationMetadataReader(signatureInspector: validSignatureInspector)

        let scannedApplication = await reader.read(
            applicationURL: fixture.bundle,
            runningState: ApplicationRunningStateSnapshot(
                bundleIdentifiers: [],
                normalizedBundlePaths: []
            )
        )
        let application = try XCTUnwrap(scannedApplication)
        let configuration = try XCTUnwrap(application.sparkleConfiguration)

        XCTAssertTrue(configuration.isEligibleForReadOnlyProbe)
        XCTAssertEqual(configuration.feedURL?.absoluteString, "https://updates.example.com/appcast.xml")
        XCTAssertEqual(configuration.frameworkRelativePath, "Contents/Frameworks/Sparkle.framework")
        XCTAssertTrue(application.sourceEvidence.contains("sparkle-readonly-probe"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                SparkleConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ),
            configuration
        )
    }

    func testInvalidOrCredentialedFeedCannotBeProbed() throws {
        for feed in [
            "http://updates.example.com/appcast.xml",
            "https://user:secret@updates.example.com/appcast.xml",
            "not a URL",
        ] {
            let fixture = try makeBundle(feedURL: feed)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            XCTAssertFalse(
                try XCTUnwrap(ApplicationMetadataReader.sparkleConfiguration(at: fixture.bundle))
                    .isEligibleForReadOnlyProbe,
                feed
            )
        }
    }

    func testMissingPublicKeyOrSignedFeedRequirementCannotBeProbed() throws {
        let missingKey = try makeBundle(publicEDKey: nil)
        defer { try? FileManager.default.removeItem(at: missingKey.root) }
        XCTAssertFalse(
            try XCTUnwrap(ApplicationMetadataReader.sparkleConfiguration(at: missingKey.bundle))
                .isEligibleForReadOnlyProbe
        )

        let unsignedFeed = try makeBundle(requiresSignedFeed: false)
        defer { try? FileManager.default.removeItem(at: unsignedFeed.root) }
        XCTAssertFalse(
            try XCTUnwrap(ApplicationMetadataReader.sparkleConfiguration(at: unsignedFeed.bundle))
                .isEligibleForReadOnlyProbe
        )
    }

    func testEscapingSparkleFrameworkSymlinkCannotBeProbed() throws {
        let fixture = try makeBundle(frameworkIsEscapingSymlink: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let configuration = try XCTUnwrap(
            ApplicationMetadataReader.sparkleConfiguration(at: fixture.bundle)
        )

        XCTAssertNil(configuration.frameworkRelativePath)
        XCTAssertFalse(configuration.isEligibleForReadOnlyProbe)
        XCTAssertFalse(ApplicationMetadataReader.hasSparkleFramework(at: fixture.bundle))
    }

    func testIncompleteSigningIdentityDoesNotContactProbe() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = RecordingSparkleProbe(outcome: .noUpdate)
        var application = try application(for: fixture.bundle)
        application.signingTeamIdentifier = nil

        let result = try await SparkleProvider(
            probe: probe,
            signatureInspector: validSignatureInspector,
            automaticAdapter: nil
        ).checkForUpdate(application)

        XCTAssertEqual(result.status, .latestVersionUnknown)
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testNoUpdateAndAvailableUpdateAreReturnedFromInjectedProbe() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let application = try application(for: fixture.bundle)

        let noUpdate = try await SparkleProvider(
            probe: RecordingSparkleProbe(outcome: .noUpdate),
            signatureInspector: validSignatureInspector,
            automaticAdapter: nil
        ).checkForUpdate(application)
        XCTAssertEqual(noUpdate.status, .upToDate)
        XCTAssertNil(noUpdate.availableVersion)

        let releaseDate = Date(timeIntervalSince1970: 1_789_000_000)
        let available = try await SparkleProvider(
            probe: RecordingSparkleProbe(outcome: .updateAvailable(
                version: ApplicationVersion(marketing: "2.0", build: "200"),
                releaseDate: releaseDate
            )),
            signatureInspector: validSignatureInspector,
            automaticAdapter: nil
        ).checkForUpdate(application)
        XCTAssertEqual(available.status, .updateAvailable)
        XCTAssertEqual(available.availableVersion, ApplicationVersion(marketing: "2.0", build: "200"))
        XCTAssertEqual(available.releaseDate, releaseDate)
    }

    func testTimeoutReturnsUnknownAndCancelsProbeTask() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = BlockingSparkleProbe()
        let result = try await SparkleProvider(
            probe: probe,
            signatureInspector: validSignatureInspector,
            probeTimeout: .milliseconds(20),
            automaticAdapter: nil
        ).checkForUpdate(application(for: fixture.bundle))

        XCTAssertEqual(result.status, .latestVersionUnknown)
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testCallerCancellationPropagatesAndCancelsProbeTask() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = BlockingSparkleProbe()
        let provider = SparkleProvider(
            probe: probe,
            signatureInspector: validSignatureInspector,
            probeTimeout: .seconds(30),
            automaticAdapter: nil
        )
        let application = try application(for: fixture.bundle)
        let task = Task { try await provider.checkForUpdate(application) }
        while await probe.callCount == 0 {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let wasCancelled = await probe.wasCancelled
            XCTAssertTrue(wasCancelled)
        }
    }

    func testProviderRemainsInApplicationAndInstallUnsupported() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let application = try application(for: fixture.bundle)
        let provider = SparkleProvider(
            probe: RecordingSparkleProbe(outcome: .noUpdate),
            signatureInspector: validSignatureInspector,
            automaticAdapter: nil
        )

        let source = try await provider.inspect(application)
        XCTAssertFalse(source.canAutomaticallyUpdate)
        XCTAssertTrue(source.requiresUserInteraction)

        do {
            _ = try await provider.prepareUpdate(application)
            XCTFail("Expected unsupported installation")
        } catch let error as ApplicationScanningError {
            guard case .providerUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testShadowHostLeavesTargetDefaultsUntouchedForUpdateAndNoUpdate() async throws {
        for outcome in [
            SparkleReadOnlyProbeOutcome.noUpdate,
            .updateAvailable(
                version: ApplicationVersion(marketing: "2.0", build: "200"),
                releaseDate: nil
            ),
        ] {
            let fixture = try makeBundle()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let recorder = ShadowSessionRecorder(behavior: .outcome(outcome))
            let provider = shadowHostProvider(recorder: recorder)

            _ = try await provider.checkForUpdate(application(for: fixture.bundle))

            // The target app's defaults cannot be touched: the shadow host's
            // settings live in its own temporary folder (N23 isolates this
            // test from the real ~/Library/Preferences as well).
            await assertShadowHostWasRemoved(recorder)
        }
    }

    func testShadowHostDoesNotCopySystemProfilingFlags() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let targetBundle = try XCTUnwrap(Bundle(url: fixture.bundle))
        XCTAssertEqual(targetBundle.object(forInfoDictionaryKey: "SUEnableSystemProfiling") as? Bool, true)
        XCTAssertEqual(targetBundle.object(forInfoDictionaryKey: "SUSendProfileInfo") as? Bool, true)
        let recorder = ShadowSessionRecorder(behavior: .outcome(.noUpdate))

        _ = try await shadowHostProvider(recorder: recorder)
            .checkForUpdate(application(for: fixture.bundle))

        let observations = await recorder.observations
        let observation = try XCTUnwrap(observations.first)
        XCTAssertNil(observation.systemProfiling)
        XCTAssertNil(observation.sendProfileInfo)
    }

    func testShadowHostLeavesTargetDefaultsUntouchedAfterTimeout() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ShadowSessionRecorder(behavior: .blockUntilCancelled)
        let provider = shadowHostProvider(
            recorder: recorder,
            timeout: .milliseconds(20)
        )

        let result = try await provider.checkForUpdate(application(for: fixture.bundle))

        XCTAssertEqual(result.status, .latestVersionUnknown)
        let wasCancelled = await recorder.wasCancelled
        XCTAssertTrue(wasCancelled)
        await assertShadowHostWasRemoved(recorder)
    }

    func testShadowHostLeavesTargetDefaultsUntouchedAfterCallerCancellation() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ShadowSessionRecorder(behavior: .blockUntilCancelled)
        let provider = shadowHostProvider(recorder: recorder, timeout: .seconds(30))
        let application = try application(for: fixture.bundle)
        let task = Task { try await provider.checkForUpdate(application) }
        while await recorder.callCount == 0 {
            await Task.yield()
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let wasCancelled = await recorder.wasCancelled
        XCTAssertTrue(wasCancelled)
        await assertShadowHostWasRemoved(recorder)
    }

    // MARK: - N23: no files in ~/Library/Preferences

    func testShadowHostKeepsSparkleSettingsOutOfTheRealPreferencesFolder() async throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ShadowSessionRecorder(behavior: .outcome(.noUpdate))

        _ = try await shadowHostProvider(recorder: recorder)
            .checkForUpdate(application(for: fixture.bundle))

        // Settings went to "<probe folder>/…plist", that folder is gone, and
        // no "<probe id>.plist" exists in ~/Library/Preferences.
        await assertShadowHostWasRemoved(recorder)
    }

    /// Sparkle records the first failed feed-signature check in the main
    /// app's standard defaults under a key named after the host bundle, and the
    /// probe's host identifier is new every time. With the grace period off
    /// (interval 0) Sparkle never writes that key; a read-only probe never
    /// used the grace period anyway, since each probe starts a new count.
    func testShadowHostTurnsOffTheSignedFeedFailureGracePeriod() async throws {
        for targetInterval: Any? in [nil, 86_400.0] {
            let fixture = try makeBundle(extraInfo: targetInterval.map {
                ["SUSignedFeedFailureExpirationInterval": $0]
            } ?? [:])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let recorder = ShadowSessionRecorder(behavior: .outcome(.noUpdate))

            _ = try await shadowHostProvider(recorder: recorder)
                .checkForUpdate(application(for: fixture.bundle))

            let observations = await recorder.observations
            let observation = try XCTUnwrap(observations.first)
            XCTAssertEqual(observation.signedFeedFailureExpirationInterval, 0, "Target interval: \(String(describing: targetInterval))")
        }
    }

    private static var realPreferencesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    private var validSignatureInspector: FixedSparkleSignatureInspector {
        FixedSparkleSignatureInspector(metadata: ApplicationCodeSignatureMetadata(
            signingTeamIdentifier: "TEAM123456",
            codeSigningIdentifier: "com.example.sparkle",
            isValid: true
        ))
    }

    private func shadowHostProvider(
        recorder: ShadowSessionRecorder,
        timeout: Duration = .seconds(2)
    ) -> SparkleProvider {
        SparkleProvider(
            probe: SystemSparkleReadOnlyProbe { hostURL, applicationURL, expectedFeedURL in
                try await recorder.run(
                    hostBundleURL: hostURL,
                    applicationBundleURL: applicationURL,
                    expectedFeedURL: expectedFeedURL
                )
            },
            signatureInspector: validSignatureInspector,
            probeTimeout: timeout,
            automaticAdapter: nil
        )
    }

    private func assertShadowHostWasRemoved(
        _ recorder: ShadowSessionRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let observations = await recorder.observations
        XCTAssertEqual(observations.count, 1, file: file, line: line)
        guard let observation = observations.first else { return }
        XCTAssertNotEqual(observation.hostIdentifier, "com.example.sparkle", file: file, line: line)
        // N23: Sparkle's settings for the probe go to an absolute-path domain
        // inside the probe's temporary folder, never to the target app's
        // domain and never to a new file in ~/Library/Preferences.
        XCTAssertTrue(
            observation.defaultsDomain.hasPrefix(observation.shadowRoot.path + "/"),
            "Settings domain \(observation.defaultsDomain) is not inside \(observation.shadowRoot.path)",
            file: file,
            line: line
        )
        XCTAssertTrue(observation.storedSettingsInShadowRoot, file: file, line: line)
        XCTAssertEqual(
            observation.feedURL,
            "https://updates.example.com/appcast.xml",
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: observation.shadowRoot.path),
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: Self.realPreferencesFolder
                .appendingPathComponent(observation.hostIdentifier + ".plist").path),
            file: file,
            line: line
        )
    }

    private func application(for bundleURL: URL) throws -> InstalledApplication {
        let configuration = try XCTUnwrap(
            ApplicationMetadataReader.sparkleConfiguration(at: bundleURL)
        )
        return InstalledApplication(
            id: "com.example.sparkle|\(bundleURL.path)",
            displayName: "Sparkle Fixture",
            bundleIdentifier: "com.example.sparkle",
            bundleURL: bundleURL,
            executableURL: bundleURL.appendingPathComponent("Contents/MacOS/SparkleFixture"),
            installedVersion: ApplicationVersion(marketing: "1.0", build: "100"),
            buildNumber: "100",
            signingTeamIdentifier: "TEAM123456",
            codeSigningIdentifier: "com.example.sparkle",
            installationSource: .sparkle,
            updateProvider: .sparkle,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            isSystemApplication: false,
            isRunning: false,
            isOnExternalVolume: false,
            isReadOnly: false,
            lastScanDate: Date(timeIntervalSince1970: 1_789_000_000),
            updateStatus: .checking,
            requiresUserInteraction: true,
            requiresApplicationQuit: false,
            requiresAdministratorAuthorization: false,
            canAutomaticallyUpdate: false,
            sourceDisplayName: "Sparkle",
            sourceEvidence: ["sparkle-framework", "sparkle-feed", "signed-bundle-identity"],
            sparkleConfiguration: configuration,
            feedURL: configuration.feedURL?.absoluteString,
            reportedCurrentVersion: "1.0"
        )
    }

    private func makeBundle(
        feedURL: String = "https://updates.example.com/appcast.xml",
        publicEDKey: String? = Data(repeating: 7, count: 32).base64EncodedString(),
        requiresSignedFeed: Bool = true,
        frameworkIsEscapingSymlink: Bool = false,
        extraInfo: [String: Any] = [:]
    ) throws -> (root: URL, bundle: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleReadOnlyProbeTests-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("SparkleFixture.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("SparkleFixture", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data([0])))

        var info: [String: Any] = [
            "CFBundleIdentifier": "com.example.sparkle",
            "CFBundleName": "Sparkle Fixture",
            "CFBundleExecutable": "SparkleFixture",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "100",
            "SUFeedURL": feedURL,
            "SURequireSignedFeed": requiresSignedFeed,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUEnableSystemProfiling": true,
            "SUSendProfileInfo": true,
        ]
        info["SUPublicEDKey"] = publicEDKey
        info.merge(extraInfo) { _, extra in extra }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

        let framework = frameworks.appendingPathComponent("Sparkle.framework", isDirectory: true)
        if frameworkIsEscapingSymlink {
            let outside = root.appendingPathComponent("Outside.framework", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: outside)
        } else {
            try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        }
        return (root, bundle)
    }
}

private struct FixedSparkleSignatureInspector: ApplicationCodeSignatureInspecting {
    let metadata: ApplicationCodeSignatureMetadata

    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata {
        metadata
    }
}

private actor RecordingSparkleProbe: SparkleReadOnlyProbing {
    private let outcome: SparkleReadOnlyProbeOutcome
    private(set) var callCount = 0

    init(outcome: SparkleReadOnlyProbeOutcome) {
        self.outcome = outcome
    }

    func probe(bundleURL: URL) async throws -> SparkleReadOnlyProbeOutcome {
        callCount += 1
        return outcome
    }
}

private actor BlockingSparkleProbe: SparkleReadOnlyProbing {
    private(set) var callCount = 0
    private(set) var wasCancelled = false

    func probe(bundleURL: URL) async throws -> SparkleReadOnlyProbeOutcome {
        callCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return .noUpdate
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

private actor ShadowSessionRecorder {
    enum Behavior: Sendable {
        case outcome(SparkleReadOnlyProbeOutcome)
        case blockUntilCancelled
    }

    struct Observation: Sendable {
        let hostIdentifier: String
        let defaultsDomain: String
        let storedSettingsInShadowRoot: Bool
        let feedURL: String
        let shadowRoot: URL
        let systemProfiling: Bool?
        let sendProfileInfo: Bool?
        let signedFeedFailureExpirationInterval: Double?
    }

    private let behavior: Behavior
    private(set) var callCount = 0
    private(set) var wasCancelled = false
    private(set) var observations: [Observation] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func run(
        hostBundleURL: URL,
        applicationBundleURL: URL,
        expectedFeedURL: URL
    ) async throws -> SparkleReadOnlyProbeOutcome {
        callCount += 1
        guard let hostBundle = Bundle(url: hostBundleURL),
              Bundle(url: applicationBundleURL) != nil,
              let hostIdentifier = hostBundle.bundleIdentifier,
              let defaultsDomain = hostBundle.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String,
              let feedURL = hostBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            throw ApplicationScanningError.invalidApplicationBundle(hostBundleURL.path)
        }
        // Stand in for Sparkle saving its settings, but only where the probe's
        // own temporary folder keeps them: a plain domain name would create a
        // file in the real ~/Library/Preferences (N23).
        let shadowRoot = hostBundleURL.deletingLastPathComponent()
        var storedSettingsInShadowRoot = false
        if defaultsDomain.hasPrefix(shadowRoot.path + "/") {
            let defaults = TestPreferenceDomain.open(suiteName: defaultsDomain)
            defaults?.set(Date(timeIntervalSince1970: 1_800_000_000), forKey: "SULastCheckTime")
            _ = defaults?.synchronize()
            storedSettingsInShadowRoot = FileManager.default.fileExists(atPath: defaultsDomain + ".plist")
        }
        observations.append(Observation(
            hostIdentifier: hostIdentifier,
            defaultsDomain: defaultsDomain,
            storedSettingsInShadowRoot: storedSettingsInShadowRoot,
            feedURL: feedURL,
            shadowRoot: shadowRoot,
            systemProfiling: hostBundle.object(forInfoDictionaryKey: "SUEnableSystemProfiling") as? Bool,
            sendProfileInfo: hostBundle.object(forInfoDictionaryKey: "SUSendProfileInfo") as? Bool,
            signedFeedFailureExpirationInterval: (hostBundle.object(
                forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval"
            ) as? NSNumber)?.doubleValue
        ))
        guard feedURL == expectedFeedURL.absoluteString else {
            throw ApplicationScanningError.providerUnsupported("sparkle-shadow-feed-mismatch")
        }

        switch behavior {
        case let .outcome(outcome):
            return outcome
        case .blockUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(30))
                return .noUpdate
            } catch is CancellationError {
                wasCancelled = true
                throw CancellationError()
            }
        }
    }
}
